#!/usr/bin/env bash
# Check that the agent is really separated from you. Changes nothing.
# Run with sudo for every check; without root some are skipped.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

case ${1:-} in
  -h|--help) echo "Usage: sudo $0   (read-only; exits 1 if any check fails)"; exit 0 ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac

n_pass=0 n_warn=0 n_fail=0 n_skip=0
pass()    { printf '  %sPASS%s  %s\n' "$C_GRN" "$C_OFF" "$*"; n_pass=$((n_pass + 1)); }
warning() { printf '  %sWARN%s  %s\n' "$C_YEL" "$C_OFF" "$*"; n_warn=$((n_warn + 1)); }
fail()    { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$*"; n_fail=$((n_fail + 1)); }
skip()    { printf '  %sSKIP%s  %s\n' "$C_DIM" "$C_OFF" "$*"; n_skip=$((n_skip + 1)); }
note()    { printf '  %sNOTE%s  %s\n' "$C_DIM" "$C_OFF" "$*"; }
section() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_OFF"; }

root=no
[[ $EUID -eq 0 ]] && root=yes
[[ $root == yes ]] || printf '%sNot root: checks that need root are skipped. Run with sudo for all of them.%s\n' "$C_DIM" "$C_OFF"

admin=${SUDO_USER:-$(id -un)}

# check_loopback NAME PORT: everything listening on PORT is loopback-only
check_loopback() {
  local name=$1 port=$2 addrs bad="" a
  addrs=$(listen_addrs "$port")
  if [[ -z $addrs ]]; then
    fail "$name: nothing listens on port $port"
    return
  fi
  while IFS= read -r a; do
    is_loopback_addr "$a" || bad+=" $a"
  done <<<"$addrs"
  if [[ -z $bad ]]; then
    pass "$name listens on loopback only ($(tr '\n' ' ' <<<"$addrs" | sed 's/ $//'))"
  else
    fail "$name is reachable from the network:$bad"
  fi
}

# unit_user UNIT: user of the unit's main process
unit_user() {
  local pid
  pid=$(systemctl show -p MainPID --value "$1" 2>/dev/null || echo 0)
  [[ $pid != 0 ]] && ps -o user= -p "$pid" 2>/dev/null | tr -d ' '
  return 0
}

# --------------------------------------------------------------------------
section "Agent user: $AGENT_USER"
if ! user_exists "$AGENT_USER"; then
  fail "user $AGENT_USER does not exist (run create-agent-user.sh)"
else
  bad=$(privileged_groups_of "$AGENT_USER" | tr '\n' ' ')
  if [[ -z $bad ]]; then pass "in no privileged group (groups: $(id -nG "$AGENT_USER"))"
  else fail "in privileged group(s): $bad"; fi

  if [[ $root == yes ]]; then
    out=$(LC_ALL=C sudo -n -l -U "$AGENT_USER" 2>&1 || true)
    if grep -qi "not allowed" <<<"$out"; then pass "sudo grants it nothing"
    else fail "sudo grants it rules: $(head -c 300 <<<"$out" | tr '\n' ' ')"; fi
    status=$(passwd -S "$AGENT_USER" 2>/dev/null | awk '{print $2}')
    case $status in
      L|LK) pass "password locked (only reachable via sudo -iu $AGENT_USER)" ;;
      NP)   fail "it has an EMPTY password: lock it with usermod -L $AGENT_USER" ;;
      *)    warning "it has a password ($status), so it can log in directly; lock it with usermod -L $AGENT_USER" ;;
    esac
  else
    skip "sudo rules and password state (need root)"
  fi

  home=$(home_of "$AGENT_USER")
  mode=$(stat -c %a "$home" 2>/dev/null || echo "?")
  if [[ $mode != "?" ]] && (( (8#$mode & 7) == 0 )); then pass "$home is $mode (other users cannot look inside)"
  else warning "$home is $mode: other users can read it"; fi

  if [[ -f /var/lib/systemd/linger/$AGENT_USER ]]; then pass "linger on: its services run without a login"
  else fail "linger off: the gateway stops when nobody is logged in as $AGENT_USER (loginctl enable-linger $AGENT_USER)"; fi
fi

open_homes=$(find /home -mindepth 1 -maxdepth 1 -type d -perm /o=rx 2>/dev/null | grep -vxF "${home:-}" || true)
if [[ -z $open_homes ]]; then pass "no home folder in /home is readable by other users"
else fail "readable by the agent: $(tr '\n' ' ' <<<"$open_homes")(chmod 700 them)"; fi

if [[ $admin != "$AGENT_USER" ]]; then
  admin_home=$(home_of "$admin")
  if [[ -d $admin_home/.openclaw ]] || pgrep -u "$admin" -f 'openclaw.*gateway' >/dev/null; then
    warning "your own account ($admin) still has OpenClaw config or a running gateway in $admin_home/.openclaw"
  else
    pass "no OpenClaw under your own account ($admin)"
  fi
fi

# --------------------------------------------------------------------------
section "Colibri: $COLIBRI_UNIT.service"
if ! systemctl cat "$COLIBRI_UNIT" >/dev/null 2>&1; then
  skip "service not installed (run install-colibri-service.sh)"
else
  if systemctl -q is-active "$COLIBRI_UNIT"; then pass "running"; else fail "not running (journalctl -u $COLIBRI_UNIT -n 50)"; fi
  if systemctl -q is-enabled "$COLIBRI_UNIT" 2>/dev/null; then pass "starts at boot"; else warning "not enabled: it won't start at boot"; fi

  u=$(unit_user "$COLIBRI_UNIT")
  if [[ $u == "$COLIBRI_USER" ]]; then pass "runs as $COLIBRI_USER"
  elif [[ -n $u ]]; then fail "runs as '$u', expected $COLIBRI_USER"; fi

  if user_exists "$COLIBRI_USER"; then
    bad=$(privileged_groups_of "$COLIBRI_USER" | tr '\n' ' ')
    if [[ -z $bad ]]; then pass "$COLIBRI_USER is in no privileged group"; else fail "$COLIBRI_USER is in privileged group(s): $bad"; fi
  fi

  check_loopback "Colibri" "$COLIBRI_PORT"

  url="http://$COLIBRI_HOST:$COLIBRI_PORT/v1/models"
  code=$(http_code "$url")
  if [[ $COLIBRI_REQUIRE_KEY == yes ]]; then
    if [[ $code == 401 || $code == 403 ]]; then pass "API refuses requests without the key ($code)"
    elif [[ $code == 200 ]]; then fail "API answers WITHOUT a key: any local process can use the model"
    else warning "API answered $code without a key (expected 401)"; fi
    if [[ $root == yes ]]; then
      if key=$(read_key) && [[ -n $key ]]; then
        code=$(http_code "$url" "$key")
        if [[ $code == 200 ]]; then pass "API accepts the key from $COLIBRI_KEY_FILE"; else fail "API answered $code with the key"; fi
      else
        fail "cannot read a key from $COLIBRI_KEY_FILE"
      fi
      perms=$(stat -c '%U:%G %a' "$COLIBRI_KEY_FILE" 2>/dev/null || true)
      if [[ $perms == "root:$COLIBRI_USER 640" ]]; then pass "key file is $perms"; else warning "key file is '$perms', expected root:$COLIBRI_USER 640"; fi
    else
      skip "API key test with the real key (needs root)"
    fi
  else
    note "COLIBRI_REQUIRE_KEY=no: any local process can use the model API"
  fi

  owner=$(stat -c %U "$COLIBRI_DIR" 2>/dev/null || echo "?")
  if [[ $owner == root ]]; then pass "$COLIBRI_DIR is owned by root"
  else warning "$COLIBRI_DIR is owned by '$owner', who can change the code the service runs"; fi

  if [[ $root == yes ]] && user_exists "$AGENT_USER"; then
    if runuser -u "$AGENT_USER" -- test -w "$COLIBRI_DIR/c/coli"; then fail "$AGENT_USER can modify the Colibri code"
    else pass "$AGENT_USER cannot modify the Colibri code"; fi
    if runuser -u "$AGENT_USER" -- test -r "$COLIBRI_KEY_FILE" 2>/dev/null; then fail "$AGENT_USER can read $COLIBRI_KEY_FILE"
    else pass "$AGENT_USER cannot read $COLIBRI_KEY_FILE"; fi
    if runuser -u "$AGENT_USER" -- test -w "$COLIBRI_STATE_DIR" 2>/dev/null; then fail "$AGENT_USER can write to $COLIBRI_STATE_DIR"
    else pass "$AGENT_USER cannot touch $COLIBRI_STATE_DIR"; fi
  else
    skip "what $AGENT_USER can access (needs root)"
  fi
fi

# --------------------------------------------------------------------------
section "Ollama: $OLLAMA_UNIT.service"
if ! systemctl cat "$OLLAMA_UNIT" >/dev/null 2>&1; then
  skip "not installed"
else
  if systemctl -q is-active "$OLLAMA_UNIT"; then pass "running"; else warning "not running"; fi
  u=$(unit_user "$OLLAMA_UNIT")
  if [[ -n $u && $u != root && $u != "$admin" && $u != "$AGENT_USER" ]]; then pass "runs as its own user ($u)"
  elif [[ -n $u ]]; then fail "runs as '$u'; it should have its own user"; fi
  check_loopback "Ollama" "$OLLAMA_PORT"
  note "Ollama has no authentication: the agent can list, pull and delete Ollama models"
fi

# --------------------------------------------------------------------------
section "OpenClaw gateway"
mapfile -t gw_pids < <(pgrep -f 'openclaw.*gateway' || true)
if (( ${#gw_pids[@]} == 0 )); then
  fail "no gateway process running"
else
  others=""
  for pid in "${gw_pids[@]}"; do
    pu=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n $pu && $pu != "$AGENT_USER" ]] && others+=" $pu(pid $pid)"
  done
  if [[ -z $others ]]; then pass "every gateway process runs as $AGENT_USER"
  else fail "gateway process(es) running as other users:$others"; fi
fi
check_loopback "Gateway" "$OPENCLAW_PORT"

if [[ $root == yes ]] && user_exists "$AGENT_USER"; then
  if as_user "$AGENT_USER" systemctl --user -q is-enabled "$OPENCLAW_UNIT.service" 2>/dev/null; then
    pass "$OPENCLAW_UNIT.service is enabled (starts at boot)"
  else
    fail "$OPENCLAW_UNIT.service is not enabled for $AGENT_USER (install-openclaw.sh --skip-onboard)"
  fi
  if [[ $COLIBRI_REQUIRE_KEY == yes ]] && systemctl cat "$COLIBRI_UNIT" >/dev/null 2>&1; then
    agent_key=$(as_user "$AGENT_USER" python3 -c "$OPENCLAW_PROVIDER_PY" "$COLIBRI_PORT" 2>/dev/null || true)
    if [[ -z $agent_key ]]; then
      fail "OpenClaw has no provider with a key for Colibri (install-openclaw.sh --key-only)"
    else
      code=$(http_code "http://$COLIBRI_HOST:$COLIBRI_PORT/v1/models" "$agent_key")
      if [[ $code == 200 ]]; then pass "OpenClaw's key works with Colibri"
      else fail "OpenClaw's key gets $code from Colibri (install-openclaw.sh --key-only)"; fi
    fi
  fi
else
  skip "gateway service and OpenClaw's Colibri key (need root)"
fi

# --------------------------------------------------------------------------
section "OpenClaw settings and sandbox"
if [[ $root == yes ]] && user_exists "$AGENT_USER" && [[ -f $(home_of "$AGENT_USER")/.openclaw/openclaw.json ]]; then
  declare -A cfg=() sbx=()
  while IFS='=' read -r k v; do cfg[$k]=$v; done < <(config_py show 2>/dev/null || true)
  agents=$(oc agents list --json 2>/dev/null | config_py agents 2>/dev/null || true)
  main_id=$(awk '$3 == "default" {print $1; exit}' <<<"$agents")
  main_ws=$(awk '$3 == "default" {print $2; exit}' <<<"$agents")
  # With several agents, sandbox explain needs --agent (it won't guess)
  while IFS='=' read -r k v; do sbx[$k]=$v; done < <(oc sandbox explain ${main_id:+--agent "$main_id"} --json 2>/dev/null | config_py explain 2>/dev/null || true)

  case ${cfg[tools_profile]:-} in
    coding|minimal|messaging) pass "tool profile: ${cfg[tools_profile]}" ;;
    "") fail "could not read OpenClaw's config" ;;
    *) warning "tool profile: ${cfg[tools_profile]}: every tool, plugin tools included (install-openclaw.sh --harden-only)" ;;
  esac
  if [[ ${cfg[browser_enabled]:-} == false ]]; then pass "browser control is off"
  else warning "browser control is on: web pages are the usual way in for prompt injection (install-openclaw.sh --harden-only)"; fi
  if [[ -n ${cfg[plugins_allow]:-} ]]; then pass "only listed plugins load: ${cfg[plugins_allow]}"
  else warning "plugins.allow is empty: any plugin found in its folders may load (install-openclaw.sh --harden-only)"; fi

  if [[ ${sbx[sandboxed]:-} == true ]]; then
    pass "the main session runs in a ${sbx[backend]} sandbox (mode ${sbx[mode]})"
    if [[ ${cfg[sandbox_network]:-} == none ]]; then pass "commands in the sandbox have no network"
    else note "commands in the sandbox can use the network (${cfg[sandbox_network]:-?})"; fi
    if [[ -z ${sbx[open_tools]:-} ]]; then pass "gateway, cron, nodes and automations tools are blocked in the sandbox"
    else fail "the sandbox lets the agent use ${sbx[open_tools]}, which act from outside it (tools.sandbox.tools)"; fi
    main_deny=$(config_py agent "${main_id:-main}" 2>/dev/null | sed -n 's/^deny=//p' || true)
    gw_usable=$(tr ',' '\n' <<<"${sbx[gateway_tools]:-}" | grep -vxF -f <(tr ',' '\n' <<<"$main_deny") | paste -sd, || true)
    note "gateway tools ${main_id:-the agent} may use from the sandbox: ${gw_usable:-none} (SANDBOX_GATEWAY_TOOLS)"
    if [[ ${cfg[external_binds]:-} == true ]]; then
      note "all sandboxes may mount folders from outside their workspace (dangerouslyAllowExternalBindSources, for SANDBOX_BINDS)"
    fi
    # Start a throwaway container the way the sandbox runs (as the agent, its
    # UID inside, no network) to see that rootless Podman and the image work.
    # Removed again by --rm.
    agent_ids="$(id -u "$AGENT_USER"):$(id -g "$AGENT_USER")"
    out=$(as_user "$AGENT_USER" timeout 60 podman run --rm --network none --read-only --cap-drop ALL \
      --userns keep-id --user "$agent_ids" openclaw-sandbox:trixie-slim \
      sh -c 'id -u; curl -s -m 3 -o /dev/null https://example.com && echo net-ok || echo net-blocked' 2>&1 || true)
    if [[ $out == "$(id -u "$AGENT_USER")"$'\n'net-blocked ]]; then
      pass "a test container from the sandbox image starts as $AGENT_USER's UID, without network"
    else
      fail "a test container from the sandbox image did not start as expected: $(tr '\n' ' ' <<<"$out" | head -c 300)"
    fi
    if [[ ${sbx[elevated]:-} == true ]]; then fail "elevated exec is on: it runs commands outside the sandbox (tools.elevated.enabled)"
    else pass "elevated exec is off"; fi
  elif [[ ${sbx[sandboxed]:-} == unknown ]]; then
    fail "openclaw sandbox explain failed: ${sbx[error]:-}"
  elif [[ ${sbx[sandboxed]:-} == false ]]; then
    warning "no sandbox: the agent's commands can change its own OpenClaw setup (install-sandbox.sh)"
    if [[ ${cfg[elevated]:-} == true ]]; then note "elevated exec is on (it only matters once there is a sandbox)"; fi
  else
    fail "openclaw sandbox explain gave no answer"
  fi

  # Two agents: the default one (shell, files) and researcher (web pages, no
  # shell, no own workspace in its sandbox, writes only the results folder).
  # main reads the results read-only.
  results=${RESEARCH_DIR:-$(home_of "$AGENT_USER")/research}
  researcher_ws=$(awk '$1 == "researcher" {print $2; exit}' <<<"$agents")
  if awk '$1 == "reader" {f=1} END {exit !f}' <<<"$agents"; then
    warning "the old 'reader' agent still exists (install-sandbox.sh replaces it with 'researcher')"
  fi
  if [[ -z $researcher_ws ]]; then
    if [[ ${sbx[sandboxed]:-} == true ]]; then warning "no researcher agent: web pages can't be read (install-sandbox.sh)"; fi
  else
    declare -A rs=() mcfg=()
    while IFS='=' read -r k v; do rs[$k]=$v; done < <(oc sandbox explain --agent researcher --json 2>/dev/null | config_py explain 2>/dev/null || true)
    while IFS='=' read -r k v; do mcfg[$k]=$v; done < <(config_py agent "$main_id" 2>/dev/null || true)
    rcfg_model=$(config_py agent researcher 2>/dev/null | sed -n 's/^model=//p' || true)
    if [[ ${rs[sandboxed]:-} != true ]]; then fail "the researcher agent is not sandboxed"
    elif [[ -n ${rs[shell_tools]:-} ]]; then fail "the researcher agent can use ${rs[shell_tools]}: it should have no shell (install-sandbox.sh)"
    elif [[ -n ${rs[open_tools]:-} ]]; then fail "the researcher agent can use ${rs[open_tools]}, which act from outside the sandbox"
    else pass "researcher agent: sandboxed, no shell"; fi
    if [[ $researcher_ws/ == "$main_ws"/* ]]; then
      fail "the researcher's workspace ($researcher_ws) is inside $main_id's, which $main_id can write: it could rewrite the researcher's instructions (delete the agent, run install-sandbox.sh)"
    fi
    if [[ " ${rs[mounts]:-}" == *" $researcher_ws:"* ]]; then
      fail "the researcher's own workspace is in its sandbox: it could rewrite its instructions (workspaceAccess must be none)"
    else
      pass "the researcher's own workspace (AGENTS.md, skills) is not in its sandbox"
    fi
    if command -v selinuxenabled >/dev/null && selinuxenabled && [[ -d $results ]]; then
      label=$(stat -c %C "$results" 2>/dev/null || true)
      if [[ $label == *:container_file_t:* ]]; then pass "SELinux lets the sandboxes use $results ($label)"
      else fail "SELinux blocks the sandboxes from $results (label ${label:-?}, needs container_file_t: install-sandbox.sh)"; fi
    fi
    if [[ " ${rs[mounts]:-} " == *" $results:/workspace/results:rw "* ]]; then pass "the researcher writes its results to $results"
    else warning "the researcher can't write to $results (install-sandbox.sh)"; fi
    if [[ ",${rs[gateway_tools]:-}," == *,web_fetch,* ]]; then pass "researcher can read web pages (web_fetch)"
    else warning "researcher can't read web pages: web_fetch is missing from its tools (install-sandbox.sh)"; fi

    if [[ ",${mcfg[deny]:-}," == *,web_fetch,* ]]; then pass "$main_id can't read web pages itself"
    else note "$main_id can read web pages itself (web_fetch in SANDBOX_GATEWAY_TOOLS)"; fi
    if [[ ${mcfg[external_binds]:-} != true && ${cfg[external_binds]:-} != true ]]; then
      fail "$main_id's sandbox won't start: OpenClaw refuses /research without dangerouslyAllowExternalBindSources (install-sandbox.sh)"
    fi
    if [[ " ${sbx[mounts]:-} " == *" $results:/research:ro "* ]]; then pass "$main_id sees the research results read-only at /research"
    elif [[ " ${sbx[mounts]:-} " == *" $results:/research:rw "* ]]; then fail "$main_id can WRITE the research results (/research must be :ro)"
    else warning "$main_id can't see the research results at /research (install-sandbox.sh)"; fi
    if [[ " ${mcfg[extra_paths]:-} " == *" $results "* ]]; then pass "$main_id's memory search covers $results"
    else warning "$main_id's memory search doesn't cover the research results (install-sandbox.sh)"; fi
    if [[ -n ${mcfg[delegate_to]:-} ]]; then
      warning "$main_id has subagents.delegateToolsTo (${mcfg[delegate_to]}): it can't work in the sandbox and makes $main_id fall back to copies of itself"
    fi
    if [[ ${rcfg_model:-unset} == set ]]; then note "researcher has its own model: it may load a second one on the GPU"; fi
    for ws in "$main_ws" "$researcher_ws"; do
      if grep -qs 'safe-local-agent:security begin' "$ws/AGENTS.md"; then pass "security instructions in $ws/AGENTS.md"
      else warning "no security instructions in $ws/AGENTS.md (install-sandbox.sh)"; fi
    done
  fi
else
  skip "OpenClaw settings and sandbox (need root and an OpenClaw config)"
fi

# --------------------------------------------------------------------------
section "SearXNG: $SEARXNG_UNIT.service"
if ! systemctl cat "$SEARXNG_UNIT" >/dev/null 2>&1; then
  skip "not installed (optional: install-searxng.sh)"
else
  if systemctl -q is-active "$SEARXNG_UNIT"; then pass "running"; else fail "not running (journalctl -u $SEARXNG_UNIT -n 40)"; fi
  check_loopback "SearXNG" "$SEARXNG_PORT"
  code=$(http_code "http://127.0.0.1:$SEARXNG_PORT/search?q=test&format=json")
  if [[ $code == 200 ]]; then pass "answers JSON searches"
  else fail "JSON search answered $code (needs search.formats: [html, json] in $SEARXNG_CONFIG_DIR/settings.yml)"; fi
  # The container's processes sit in libpod-payload-*; Podman's own conmon (root) does not.
  cg=$(systemctl show -p ControlGroup --value "$SEARXNG_UNIT" 2>/dev/null || true)
  uids=""
  if [[ -n $cg ]]; then
    uids=$(find "/sys/fs/cgroup$cg" -path '*libpod-payload-*' -name cgroup.procs -exec cat {} + 2>/dev/null \
      | while read -r p; do stat -c %u "/proc/$p" 2>/dev/null; done | sort -u | paste -sd ' ')
  fi
  if [[ -z $uids ]]; then warning "could not find the container's processes"
  elif [[ " $uids" == *" 0 "* ]]; then fail "the container runs as real root: an escape would be root on this machine (UserNS=auto)"
  else pass "the container runs in its own user namespace (host UID $uids)"; fi
  if [[ $root == yes ]] && user_exists "$AGENT_USER" && [[ -f $(home_of "$AGENT_USER")/.openclaw/openclaw.json ]]; then
    if [[ ${cfg[web_search_provider]:-} == searxng ]]; then pass "OpenClaw searches with SearXNG (${cfg[searxng_url]:-?})"
    else note "OpenClaw's web search provider is ${cfg[web_search_provider]:-unset}, not searxng (install-searxng.sh)"; fi
  fi
fi

# --------------------------------------------------------------------------
section "This machine"
docker_members=$(getent group docker | cut -d: -f4 | tr ',' ' ')
if [[ " $docker_members " == *" $admin "* ]]; then
  warning "your account ($admin) is in the docker group: root without a password for anything running as you (gpasswd -d $admin docker)"
fi
if systemctl -q is-active docker.service 2>/dev/null; then
  if command -v podman >/dev/null; then warning "Docker is running: its firewall rules also block Podman containers (SearXNG, the sandbox)"
  else note "Docker is running"; fi
else
  pass "Docker is not running"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd -q --state 2>/dev/null; then
  wide=""
  for zone in $(firewall-cmd --get-active-zones 2>/dev/null | awk '/^[^ \t]/ {print $1}'); do
    [[ $(firewall-cmd --zone="$zone" --get-target 2>/dev/null) == ACCEPT ]] && wide+=" $zone(accepts everything)"
    for p in $(firewall-cmd --zone="$zone" --list-ports 2>/dev/null); do
      range=${p%/*}
      [[ $range == *-* ]] || continue
      if (( ${range#*-} - ${range%-*} >= 1000 )); then wide+=" $zone($p)"; fi
    done
  done
  if [[ -z $wide ]]; then pass "the firewall opens no wide port ranges"
  else warning "your network can reach any port the agent opens:$wide (README: Firewall)"; fi
else
  skip "firewall (firewalld is not running)"
fi

# --------------------------------------------------------------------------
printf '\n%s%d passed%s, %s%d warnings%s, %s%d failed%s, %d skipped\n' \
  "$C_GRN" "$n_pass" "$C_OFF" "$C_YEL" "$n_warn" "$C_OFF" "$C_RED" "$n_fail" "$C_OFF" "$n_skip"
(( n_fail == 0 ))
