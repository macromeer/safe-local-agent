#!/usr/bin/env bash
# Install OpenClaw for the agent user, set it up for Colibri (no questions:
# the script knows the URL, the model and the key), harden it and install the
# gateway as a systemd user service.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [--interactive | --skip-onboard | --key-only | --harden-only]

  (no option)     install openclaw@$OPENCLAW_VERSION for $AGENT_USER and set it up
                  without questions: Colibri as the model provider (with its key),
                  gateway on loopback with a token, memory search with Ollama's
                  $OLLAMA_EMBED_MODEL if it is there; then the hardened settings and
                  the gateway service. An existing OpenClaw config is kept.
  --interactive   the same, but with OpenClaw's own setup wizard
  --skip-onboard  same as no option, but never set up a new config
  --key-only      only write the Colibri key into the config and restart the gateway
  --harden-only   only apply the hardened settings and restart the gateway

Hardened settings (OPENCLAW_HARDEN=$OPENCLAW_HARDEN; "no" leaves them to you):
  tools.profile coding, browser.enabled false, tools.elevated.enabled false,
  and plugins.allow = OPENCLAW_PLUGINS ($OPENCLAW_PLUGINS) if it is empty
EOF
}

mode=full
case ${1:-} in
  "") ;;
  --interactive)  mode="interactive" ;;
  --skip-onboard) mode="skip-onboard" ;;
  --key-only)     mode="key-only" ;;
  --harden-only)  mode="harden-only" ;;
  -h|--help)      usage; exit 0 ;;
  *)              usage >&2; die "unknown option: $1" ;;
esac

need_root
need_cmd runuser curl python3 ss
user_exists "$AGENT_USER" || die "user $AGENT_USER does not exist. Run create-agent-user.sh first."
[[ -z $(privileged_groups_of "$AGENT_USER") ]] || die "$AGENT_USER is in a privileged group. Run create-agent-user.sh first."
uid=$(id -u "$AGENT_USER")
[[ -S /run/user/$uid/bus ]] || die "systemd --user is not running for $AGENT_USER. Run create-agent-user.sh (it enables linger)."

base_url="http://$COLIBRI_HOST:$COLIBRI_PORT/v1"
key=""
if [[ $COLIBRI_REQUIRE_KEY == yes && $mode != harden-only ]]; then
  key=$(read_key) || die "cannot read the API key from $COLIBRI_KEY_FILE. Run install-colibri-service.sh first."
fi

set_key() {
  [[ -n $key ]] || return 0
  log "writing the Colibri API key into $AGENT_USER's OpenClaw config"
  printf '%s\n' "$key" | as_user "$AGENT_USER" python3 -c "$(<"$SLA_ROOT/lib/set_openclaw_key.py")" "$COLIBRI_PORT" \
    || die "could not set the key. Is there a model provider with base URL $base_url in ~$AGENT_USER/.openclaw/openclaw.json?"
}

wait_for_gateway() {
  local a
  for _ in $(seq 30); do
    a=$(listen_addrs "$OPENCLAW_PORT")
    if [[ -n $a ]]; then
      while IFS= read -r line; do
        is_loopback_addr "$line" || warn "the gateway listens on $line, not only on loopback"
      done <<<"$a"
      log "gateway is listening on port $OPENCLAW_PORT"
      return 0
    fi
    sleep 2
  done
  warn "the gateway is not listening on port $OPENCLAW_PORT yet. Check: sudo -iu $AGENT_USER openclaw gateway status"
}

# set_cfg KEY VALUE [ARGS...]: openclaw config set, which validates the change
set_cfg() { oc config set "$@" >/dev/null || die "OpenClaw refused to set $1 (see the message above)"; }

# The settings `openclaw security audit` asks for: no browser and no plugin
# tools for the agent, no elevated exec (it would bypass a sandbox), and only
# the plugins you list.
harden() {
  if [[ $OPENCLAW_HARDEN != yes ]]; then
    log "OPENCLAW_HARDEN=$OPENCLAW_HARDEN: leaving tool, browser and plugin settings alone"
    return 0
  fi
  log "hardening OpenClaw: tools.profile coding, browser off, elevated exec off"
  set_cfg tools.profile coding
  set_cfg browser.enabled false --strict-json
  set_cfg tools.elevated.enabled false --strict-json
  local allow ids
  allow=$(config_py show | sed -n 's/^plugins_allow=//p')
  if [[ -z $allow ]]; then
    read -ra ids <<<"$OPENCLAW_PLUGINS"
    set_cfg plugins.allow "$(config_py plugins-json "${ids[@]}")" --strict-json
    log "plugins.allow: ${ids[*]} (memory-core, the memory plugin, loads anyway)"
  else
    log "plugins.allow is already set, kept as is: $allow"
  fi
}

if [[ $mode == harden-only ]]; then
  [[ -f $(home_of "$AGENT_USER")/.openclaw/openclaw.json ]] || die "no OpenClaw config for $AGENT_USER yet. Run this script without options first."
  harden
  oc gateway restart >/dev/null || warn "gateway restart failed: sudo -iu $AGENT_USER openclaw gateway status"
  wait_for_gateway
  exit 0
fi

if [[ $mode == key-only ]]; then
  set_key
  as_user "$AGENT_USER" openclaw gateway restart
  wait_for_gateway
  exit 0
fi

need_cmd node npm
node_major=$(node -p 'process.versions.node.split(".")[0]')
(( node_major >= 22 )) || warn "Node.js $node_major is old; OpenClaw needs a current Node.js (tested with 24)"

home=$(home_of "$AGENT_USER")
log "installing openclaw@$OPENCLAW_VERSION for $AGENT_USER into $home/.local"
as_user "$AGENT_USER" npm config set prefix "$home/.local"
as_user "$AGENT_USER" npm install -g --no-fund --no-audit "openclaw@$OPENCLAW_VERSION"
# shellcheck disable=SC2016  # expanded by the agent's shell, not here
as_user "$AGENT_USER" bash -c 'grep -qs "\.local/bin" ~/.bashrc || printf "\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\n" >> ~/.bashrc'
log "installed: $(as_user "$AGENT_USER" openclaw --version 2>/dev/null | head -n 1)"

config=$home/.openclaw/openclaw.json
if [[ $mode == full && -f $config ]]; then
  log "keeping the existing OpenClaw config (to start over: uninstall.sh --agent-user; for the wizard: --interactive)"
  mode=skip-onboard
fi

if [[ $mode == full ]]; then
  model_id=$COLIBRI_MODEL_ID
  if [[ -z $model_id ]]; then
    model_id=$(curl_auth "$key" "$base_url/models" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data", []); print(d[0]["id"] if d else "")' 2>/dev/null || true)
  fi
  [[ -n $model_id ]] || die "Colibri lists no model at $base_url/models (journalctl -u $COLIBRI_UNIT), or set COLIBRI_MODEL_ID"
  log "setting up OpenClaw for $AGENT_USER: model colibri/$model_id, gateway on 127.0.0.1:$OPENCLAW_PORT with a token"
  # The key goes in through stdin into the environment (CUSTOM_API_KEY),
  # never on a command line. Search, channels and skills are left out here:
  # install-searxng.sh does the web search.
  onboard=(openclaw onboard --non-interactive --accept-risk --skip-health
    --auth-choice custom-api-key --custom-provider-id colibri --custom-compatibility openai
    --custom-base-url "$base_url" --custom-model-id "$model_id" --secret-input-mode plaintext
    --gateway-bind loopback --gateway-auth token --gateway-port "$OPENCLAW_PORT"
    --skip-daemon --skip-search --skip-channels --skip-skills)
  [[ -n $key ]] || onboard+=(--custom-no-auth)   # COLIBRI_REQUIRE_KEY=no
  # shellcheck disable=SC2016  # expanded by the agent's shell, not here
  printf '%s\n' "$key" | as_user "$AGENT_USER" bash -c 'read -r k; [[ -z $k ]] || export CUSTOM_API_KEY=$k; exec "$@"' _ \
    "${onboard[@]}" || die "OpenClaw's setup failed (see above)"
elif [[ $mode == interactive ]]; then
  cat <<EOF

${C_B}OpenClaw's setup wizard starts now, as $AGENT_USER.${C_OFF} When it asks, enter:

  model provider   Custom Provider, OpenAI-compatible
  base URL         $base_url
  API key          leave empty: this script puts the real key in afterwards
                   (the wizard then can't list the models: enter the model id)
  model id         $(curl_auth "$key" "$base_url/models" 2>/dev/null | python3 -c 'import json,sys; print(", ".join(m["id"] for m in json.load(sys.stdin).get("data", [])))' 2>/dev/null || echo "(Colibri is not answering)")
  gateway          local mode, bind loopback, token auth

When it offers to install the gateway service, you can say no; this script does it next.

EOF
  read -rp "Press Enter to start the wizard... " _ || true
  as_user "$AGENT_USER" openclaw onboard \
    || warn "the setup wizard reported a problem (expected if it couldn't sign in to Colibri without the key); continuing"
fi

# Memory search with Ollama's embedding model, if nobody chose a provider yet
if ! oc config get memory.search.provider >/dev/null 2>&1; then
  if curl -s --max-time 5 "http://127.0.0.1:$OLLAMA_PORT/api/tags" \
      | python3 -c 'import json,sys; m=sys.argv[1]; sys.exit(0 if any(x["name"] in (m, m+":latest") for x in json.load(sys.stdin).get("models", [])) else 1)' \
        "$OLLAMA_EMBED_MODEL" 2>/dev/null; then
    set_cfg memory.search.provider ollama
    set_cfg memory.search.model "$OLLAMA_EMBED_MODEL"
    log "memory search: Ollama, $OLLAMA_EMBED_MODEL"
  else
    warn "Ollama has no $OLLAMA_EMBED_MODEL: memory search stays keyword-only (ollama pull $OLLAMA_EMBED_MODEL, then run this again)"
  fi
fi

set_key
harden

if [[ $PONYTAIL == yes ]]; then
  log "installing the ponytail skills ($PONYTAIL_REF) into $home/.openclaw/skills"
  # Downloaded and unpacked as the agent, so the files end up owned by it.
  # shellcheck disable=SC2016  # $1 is expanded by the inner bash, not here
  as_user "$AGENT_USER" bash -c 'mkdir -p ~/.openclaw/skills && curl -fsSL "$1" | tar -xz -C ~/.openclaw/skills --strip-components=3 --wildcards "*/.openclaw/skills/*"' \
    _ "https://github.com/DietrichGebert/ponytail/archive/$PONYTAIL_REF.tar.gz" \
    || warn "could not install the ponytail skills"
fi

log "installing the gateway as a systemd user service for $AGENT_USER"
as_user "$AGENT_USER" openclaw gateway install
as_user "$AGENT_USER" systemctl --user enable -q "$OPENCLAW_UNIT.service" 2>/dev/null \
  || warn "could not enable $OPENCLAW_UNIT.service; check: systemctl --user is-enabled $OPENCLAW_UNIT"
as_user "$AGENT_USER" openclaw gateway restart >/dev/null || true
wait_for_gateway

cat <<EOF

${C_B}Done.${C_OFF} The agent runs as $AGENT_USER.
  dashboard   http://127.0.0.1:$OPENCLAW_PORT
  token       sudo -iu $AGENT_USER openclaw gateway auth-token --show
  check all   sudo $SLA_ROOT/scripts/verify.sh
EOF
