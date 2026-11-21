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
printf '\n%s%d passed%s, %s%d warnings%s, %s%d failed%s, %d skipped\n' \
  "$C_GRN" "$n_pass" "$C_OFF" "$C_YEL" "$n_warn" "$C_OFF" "$C_RED" "$n_fail" "$C_OFF" "$n_skip"
(( n_fail == 0 ))
