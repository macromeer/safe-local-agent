#!/usr/bin/env bash
# Install OpenClaw for the agent user, run its setup, hand it the Colibri key
# and install the gateway as a systemd user service.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [--skip-onboard | --key-only]

  (no option)     install openclaw@$OPENCLAW_VERSION for $AGENT_USER, run
                  'openclaw onboard', set the Colibri key, install the gateway
  --skip-onboard  same, but keep the existing OpenClaw config (no wizard)
  --key-only      only write the Colibri key into the config and restart the gateway
EOF
}

mode=full
case ${1:-} in
  "") ;;
  --skip-onboard) mode="skip-onboard" ;;
  --key-only)     mode="key-only" ;;
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
if [[ $COLIBRI_REQUIRE_KEY == yes ]]; then
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

if [[ $mode == full ]]; then
  model_ids=$(curl_auth "$key" "$base_url/models" 2>/dev/null \
    | python3 -c 'import json,sys; print(", ".join(m["id"] for m in json.load(sys.stdin).get("data", [])))' 2>/dev/null || true)
  cat <<EOF

${C_B}OpenClaw's setup wizard starts now, as $AGENT_USER.${C_OFF} When it asks, enter:

  model provider   OpenAI-compatible / custom
  base URL         $base_url
  model id         ${model_ids:-(Colibri is not answering; see journalctl -u $COLIBRI_UNIT)}
  API key          anything: this script puts the real key in afterwards
  gateway          local mode, bind loopback, token auth
  memory search    Ollama (http://127.0.0.1:$OLLAMA_PORT), if you use it for embeddings

When it offers to install the gateway service, you can say no; this script does it next.

EOF
  read -rp "Press Enter to start the wizard... " _ || true
  as_user "$AGENT_USER" openclaw onboard
fi

set_key

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
