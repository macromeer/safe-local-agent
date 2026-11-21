#!/usr/bin/env bash
# Run the agent's tools in a rootless Podman container inside the agent user,
# so its commands can't change its own OpenClaw setup (config, plugins,
# systemd user services) and, by default, have no network.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

IMAGE=openclaw-sandbox:trixie-slim
RESEARCHER=researcher

usage() {
  cat <<EOF
Usage: sudo $0 [--off]

  (no option)  give $AGENT_USER subordinate UIDs for rootless Podman, build the
               sandbox image as $AGENT_USER, sandbox every session
               (mode all, backend podman), turn elevated exec off, restart
               the gateway and show what OpenClaw reports
  --off        set the sandbox mode back to off and restart the gateway

Settings (config.env):
  SANDBOX_NETWORK=$SANDBOX_NETWORK      none, or bridge for internet access
  SANDBOX_WORKSPACE=$SANDBOX_WORKSPACE       what the sandbox sees of the agent's workspace: none, ro, rw
  SANDBOX_BINDS="$SANDBOX_BINDS"      extra folders, space-separated /host:/in/sandbox:ro (or :rw)
  SANDBOX_GATEWAY_TOOLS="$SANDBOX_GATEWAY_TOOLS"
                     tools that run in the gateway but may be used from the sandbox
EOF
}

mode=on
case ${1:-} in
  "") ;;
  --off)     mode=off ;;
  -h|--help) usage; exit 0 ;;
  *)         usage >&2; die "unknown option: $1" ;;
esac

need_root
need_cmd runuser python3
user_exists "$AGENT_USER" || die "user $AGENT_USER does not exist. Run create-agent-user.sh first."
home=$(home_of "$AGENT_USER")
[[ -f $home/.openclaw/openclaw.json ]] || die "no OpenClaw config for $AGENT_USER. Run install-openclaw.sh first."
as_user "$AGENT_USER" systemctl --user cat "$OPENCLAW_UNIT.service" >/dev/null 2>&1 \
  || die "the gateway service $OPENCLAW_UNIT.service is not installed for $AGENT_USER. Run install-openclaw.sh (or --skip-onboard) first."

restart_gateway() {
  log "restarting the gateway"
  oc gateway restart >/dev/null || warn "gateway restart failed: sudo -iu $AGENT_USER openclaw gateway status"
}

if [[ $mode == off ]]; then
  oc config set agents.defaults.sandbox.mode off >/dev/null || die "OpenClaw refused the change"
  restart_gateway
  log "sandbox off. Old containers: sudo -iu $AGENT_USER podman ps -a"
  exit 0
fi

need_cmd podman usermod
[[ -x /usr/libexec/podman/catatonit ]] || command -v catatonit >/dev/null \
  || warn "catatonit (Podman's init) not found; install it if sandboxes fail to start"

# Rootless Podman needs a range of subordinate UIDs/GIDs for the agent.
# next_free_range: start of a 65536-wide range after every range in use
next_free_range() {
  local min
  min=$(awk '$1 == "SUB_UID_MIN" {print $2}' /etc/login.defs 2>/dev/null)
  cat /etc/subuid /etc/subgid 2>/dev/null | awk -F: -v min="${min:-100000}" '
    $1 != "containers" && NF >= 3 { end = $2 + $3; if (end > top) top = end }
    END { print (top > min ? top : min) }'
}
if grep -qs "^$AGENT_USER:" /etc/subuid && grep -qs "^$AGENT_USER:" /etc/subgid; then
  log "$AGENT_USER already has subordinate UIDs/GIDs"
else
  start=$(next_free_range)
  end=$((start + 65535))
  grep -qs "^$AGENT_USER:" /etc/subuid || usermod --add-subuids "$start-$end" "$AGENT_USER"
  grep -qs "^$AGENT_USER:" /etc/subgid || usermod --add-subgids "$start-$end" "$AGENT_USER"
  log "gave $AGENT_USER subordinate UIDs/GIDs $start-$end"
  as_user "$AGENT_USER" podman system migrate >/dev/null 2>&1 || true
fi

if as_user "$AGENT_USER" podman image exists "$IMAGE"; then
  log "sandbox image $IMAGE exists (to rebuild: sudo -iu $AGENT_USER podman rmi $IMAGE)"
else
  log "building the sandbox image $IMAGE as $AGENT_USER (downloads debian:trixie-slim)"
  # The image OpenClaw's docs give for npm installs (gateway/sandboxing/images-and-setup)
  as_user "$AGENT_USER" podman build -q -t "$IMAGE" - <<'DOCKERFILE'
FROM docker.io/library/debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash ca-certificates curl git jq python3 ripgrep \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
DOCKERFILE
fi

# The container runs as the agent's own UID (rootless Podman maps it to the
# agent with keep-id), so it gets exactly the agent's file permissions.
read -ra binds <<<"$SANDBOX_BINDS"
for b in "${binds[@]}"; do
  runuser -u "$AGENT_USER" -- test -r "${b%%:*}" \
    || warn "$AGENT_USER cannot read ${b%%:*}, so the sandbox can't either (README: Share a folder)"
done
sandbox=$(config_py sandbox-json "$SANDBOX_NETWORK" "$SANDBOX_WORKSPACE" \
  "$(id -u "$AGENT_USER"):$(id -g "$AGENT_USER")" "${binds[@]}") || die "bad sandbox setting (see above)"

log "sandboxing every session (network $SANDBOX_NETWORK, workspace $SANDBOX_WORKSPACE)"
oc config set agents.defaults.sandbox "$sandbox" --strict-json --merge >/dev/null || die "OpenClaw refused the sandbox settings"
# Elevated exec runs commands outside the sandbox
oc config set tools.elevated.enabled false --strict-json >/dev/null || die "OpenClaw refused tools.elevated.enabled"
# Gateway-side tools the sandbox may use (OpenClaw's default allows none, so
# without this the agents have no web search and no memory search)
read -ra gw_tools <<<"$SANDBOX_GATEWAY_TOOLS"
also=$(config_py also-allow-json "${gw_tools[@]}") || die "bad SANDBOX_GATEWAY_TOOLS (see above)"
oc config set tools.sandbox.tools.alsoAllow "$also" --strict-json >/dev/null || die "OpenClaw refused tools.sandbox.tools.alsoAllow"

# --- Two agents. main: shell and files, no web pages. researcher: reads web
# pages and writes results into its own workspace, no shell. main reads that
# workspace read-only. (OpenClaw can't let a sandboxed main hand web_fetch to
# a child agent, so you start research from the agent picker.)

# list_add / list_remove PATH ITEM...: change a list in OpenClaw's config
list_change() {
  local op=$1 path=$2 current
  shift 2
  current=$(oc config get "$path" --json 2>/dev/null || true)
  oc config set "$path" "$(printf '%s' "$current" | config_py "$op" "$@")" --strict-json >/dev/null \
    || die "OpenClaw refused $path"
}
list_add()    { list_change list-add "$@"; }
list_remove() { list_change list-remove "$@"; }

stop_gateway() {
  as_user "$AGENT_USER" systemctl --user stop "$OPENCLAW_UNIT.service" || die "could not stop $OPENCLAW_UNIT.service"
  local _
  for _ in $(seq 30); do
    pgrep -u "$AGENT_USER" -f 'openclaw.*gateway' >/dev/null || return 0
    sleep 1
  done
  die "the gateway is still running; stop it and run this again"
}
start_gateway() {
  as_user "$AGENT_USER" systemctl --user start "$OPENCLAW_UNIT.service" \
    || warn "could not start $OPENCLAW_UNIT.service: sudo -iu $AGENT_USER openclaw gateway status"
  local _
  for _ in $(seq 30); do [[ -n $(listen_addrs "$OPENCLAW_PORT") ]] && return 0; sleep 1; done
  warn "the gateway is not listening on port $OPENCLAW_PORT yet"
}
list_agents() { oc agents list --json 2>/dev/null | config_py agents; }

agents=$(list_agents) || die "could not list OpenClaw's agents"
main=$(awk '$3 == "default" {print $1; exit}' <<<"$agents")
[[ -n $main ]] || die "OpenClaw reports no default agent"
[[ $main != "$RESEARCHER" ]] || die "the default agent is '$RESEARCHER'; this script expects it to be a different one"
results=${RESEARCH_DIR:-$home/research}

# Earlier versions of this script: a 'reader' agent that main could start (a
# hand-off that can't work in the sandbox), and a researcher whose workspace
# was $results itself, locked with chattr +i (Podman can't label such files
# for SELinux, so its sandbox never started). Clean both up.
list_remove "agents.entries.$main.subagents.allowAgents" reader
list_remove "agents.entries.$main.subagents.delegateToolsTo" reader
if awk '$1 == "reader" && $2 ~ /\/workspace-reader$/ {f=1} END {exit !f}' <<<"$agents"; then
  log "removing the old 'reader' agent (its workspace goes to the Trash)"
  oc agents delete reader --force >/dev/null 2>&1 || warn "could not delete the agent 'reader': sudo -iu $AGENT_USER openclaw agents delete reader --force"
fi
if [[ -d $results ]] && lsattr -d "$results" 2>/dev/null | awk '{exit $1 !~ /i/}'; then
  log "unlocking $results (chattr -i, left by an earlier version)"
  chattr -R -i "$results" 2>/dev/null || true
fi
if awk -v r="$RESEARCHER" -v w="$results" '$1 == r && $2 == w {f=1} END {exit !f}' <<<"$agents"; then
  die "the agent '$RESEARCHER' still uses $results as its workspace (an earlier version). Delete it and run this again: sudo -iu $AGENT_USER openclaw agents delete $RESEARCHER --force"
fi
if as_user "$AGENT_USER" test -f "$results/AGENTS.md"; then
  die "$results still holds an old researcher workspace (AGENTS.md). Finish its deletion first: sudo -iu $AGENT_USER openclaw agents delete $RESEARCHER --force   (if OpenClaw no longer knows it: move $results away)"
fi

if ! awk '{print $1}' <<<"$agents" | grep -qx "$RESEARCHER"; then
  # A role needs exclusive offline state ownership: stop the gateway through
  # its service owner (systemd) and wait until it has let go.
  log "creating the agent '$RESEARCHER' (OpenClaw's researcher role; the gateway stops for this)"
  stop_gateway
  # Always an explicit workspace: without it OpenClaw may put it under
  # agents.defaults.workspace, i.e. inside main's (writable) workspace.
  if ! out=$(oc agents add "$RESEARCHER" --role researcher --workspace "$home/.openclaw/workspace-$RESEARCHER" \
      --non-interactive 2>&1); then
    start_gateway
    printf '%s\n' "$out" | grep -v '^[│◇ ]*$' | tail -n 5 | sed 's/^/    /' >&2
    die "could not create the agent '$RESEARCHER' (the gateway was started again)"
  fi
  start_gateway
fi
agents=$(list_agents)
researcher_ws=$(awk -v r="$RESEARCHER" '$1 == r {print $2; exit}' <<<"$agents")
main_ws=$(awk '$3 == "default" {print $2; exit}' <<<"$agents")
[[ -n $researcher_ws ]] || die "OpenClaw does not list the agent '$RESEARCHER'"
# main's workspace is writable from main's sandbox: the researcher's
# instructions must not be in it (or under it)
case $researcher_ws/ in
  "$main_ws"/*)
    die "$RESEARCHER's workspace ($researcher_ws) is inside $main's workspace, so $main could rewrite its instructions. Delete the agent (sudo -iu $AGENT_USER openclaw agents delete $RESEARCHER --force) and run this again: it then gets $home/.openclaw/workspace-$RESEARCHER" ;;
esac
as_user "$AGENT_USER" mkdir -p "$results"
# SELinux: containers may not touch files labelled user_home_t, and Podman
# doesn't relabel OpenClaw's bind mounts. Label the results folder (and what
# is created in it) container_file_t, as a permanent rule.
if command -v selinuxenabled >/dev/null && selinuxenabled; then
  if command -v semanage >/dev/null; then
    rule="$results(/.*)?"
    semanage fcontext -a -t container_file_t "$rule" 2>/dev/null \
      || semanage fcontext -m -t container_file_t "$rule" \
      || die "could not add the SELinux rule for $results"
    restorecon -R "$results"
  else
    chcon -R -t container_file_t "$results"
    warn "semanage is missing: the SELinux label on $results is lost on a relabel (dnf install policycoreutils-python-utils)"
  fi
  log "SELinux: $results is container_file_t (the sandboxes may use it)"
fi
config_py check-bind "$results:/research:ro" || die "$results can't be mounted into the sandboxes (see above)"

# researcher: web pages, no shell. Its sandbox doesn't get its own workspace
# (workspaceAccess none: an isolated scratch workspace instead), so it can't
# change its AGENTS.md or add skills; only the results folder is mounted in,
# inside /workspace because OpenClaw's write tools stay within /workspace.
# OpenClaw reserves /workspace for its own mounts, so this one bind needs
# dangerouslyAllowReservedContainerTargets (researcher only); check-bind makes
# sure it doesn't hide anything OpenClaw mounts there.
config_py check-bind "$results:/workspace/results:rw" || die "the results folder can't be mounted for $RESEARCHER (see above)"
list_add "agents.entries.$RESEARCHER.tools.deny" exec process apply_patch
oc config set "agents.entries.$RESEARCHER.tools.sandbox.tools.allow" \
  "$(config_py plugins-json read ls write edit web_search web_fetch)" --strict-json >/dev/null \
  || die "OpenClaw refused the researcher's tool list"
oc config set "agents.entries.$RESEARCHER.sandbox" \
  "{\"workspaceAccess\": \"none\", \"docker\": {\"binds\": [\"$results:/workspace/results:rw\"], \"dangerouslyAllowExternalBindSources\": true, \"dangerouslyAllowReservedContainerTargets\": true}}" \
  --strict-json --merge >/dev/null || die "OpenClaw refused the researcher's sandbox settings"

# main: no web pages itself; the results read-only at /research and in its
# memory search. OpenClaw only mounts folders from outside main's workspace
# with dangerouslyAllowExternalBindSources (for main only); its checks for
# system, credential and socket paths stay on.
if [[ " ${gw_tools[*]} " != *" web_fetch "* ]]; then
  list_add "agents.entries.$main.tools.deny" web_fetch
fi
list_add "agents.entries.$main.sandbox.docker.binds" "$results:/research:ro"
oc config set "agents.entries.$main.sandbox.docker.dangerouslyAllowExternalBindSources" true --strict-json >/dev/null \
  || die "OpenClaw refused agents.entries.$main.sandbox.docker.dangerouslyAllowExternalBindSources"
list_remove "agents.entries.$main.memory.search.extraPaths" "{\"path\": \"$results/results\", \"pattern\": \"**/*.md\"}"
list_add "agents.entries.$main.memory.search.extraPaths" "{\"path\": \"$results\", \"pattern\": \"**/*.md\"}"
log "agents: $main (shell, files, web search) reads what $RESEARCHER (web pages) saves in $results"

# Security instructions in each workspace's AGENTS.md, between markers. They
# help, but they are not a boundary: the tool lists and mounts above are.
for pair in "$main:$main_ws:main.md" "$RESEARCHER:$researcher_ws:researcher.md"; do
  IFS=: read -r id ws file <<<"$pair"
  [[ $id == "$RESEARCHER" ]] && as_user "$AGENT_USER" touch "$ws/AGENTS.md"
  if as_user "$AGENT_USER" test -f "$ws/AGENTS.md"; then
    config_py put-block "$ws/AGENTS.md" security <"$SLA_ROOT/agent-instructions/$file" >/dev/null \
      || warn "could not update $ws/AGENTS.md"
    log "security instructions in $ws/AGENTS.md"
  else
    warn "$ws/AGENTS.md does not exist yet: chat with $id once, then run this again"
  fi
done

# Running sandboxes keep their old mounts and settings until recreated, and
# leftovers of deleted agents keep running. Recreating is offline-only:
# stop the gateway through systemd, recreate, start it again.
log "recreating the sandboxes with the new settings (the gateway stops for this)"
stop_gateway
if ! out=$(oc sandbox recreate --all --force 2>&1); then
  warn "could not recreate the sandboxes; old ones keep their old mounts until you do (with the gateway stopped): openclaw sandbox recreate --all --force"
  printf '%s\n' "$out" | grep -v '^[│◇ ]*$' | tail -n 5 | sed 's/^/    /' >&2
fi
start_gateway

for id in "$main" "$RESEARCHER"; do
  report=$(oc sandbox explain --agent "$id" --json 2>/dev/null | config_py explain || true)
  printf '  %s:\n' "$id"
  printf '%s\n' "$report" | sed 's/^/    /'
  grep -qx 'sandboxed=true' <<<"$report" || die "OpenClaw does not report $id as sandboxed"
  grep -qx 'open_tools=' <<<"$report" || warn "$id can use tools that act from outside the sandbox: $(sed -n 's/^open_tools=//p' <<<"$report")"
  if [[ $id == "$RESEARCHER" ]]; then
    grep -qx 'shell_tools=' <<<"$report" || die "$RESEARCHER can still use: $(sed -n 's/^shell_tools=//p' <<<"$report")"
    grep -q " $results:/workspace/results:rw" <<<"$report" || warn "OpenClaw doesn't list $results at /workspace/results for $RESEARCHER"
    if grep -q "^mounts=.*$researcher_ws:" <<<"$report"; then die "$RESEARCHER's own workspace is in its sandbox; it could change its instructions"; fi
  else
    grep -q "^mounts=.* $results:/research:ro" <<<"$report" || warn "OpenClaw doesn't list $results read-only at /research for $main"
  fi
done

cat <<EOF

${C_B}Done.${C_OFF} The agents' tools run in Podman containers as $AGENT_USER. Test it in the dashboard:
  1. ask $main to run: cat $home/.openclaw/openclaw.json            must fail (not in the sandbox)
  2. ask $main to run: curl -sI https://example.com                  must fail with SANDBOX_NETWORK=none
  3. ask $main to create, edit and read a file in its workspace       must work
  4. ask $main to search the web                                     must work (runs in the gateway)
  5. pick $RESEARCHER, ask it to research a topic                       must save $results/<date>-<topic>.md
     then ask $main what the researcher found about it                must find and cite that file
  6. ask $RESEARCHER to run a command                                  must fail
     ask it to add a line to its AGENTS.md, then check the real file:  must be unchanged
       sudo tail -3 $researcher_ws/AGENTS.md
Containers: sudo -iu $AGENT_USER podman ps    Check all: sudo $SLA_ROOT/scripts/verify.sh
EOF
