#!/usr/bin/env bash
# End-to-end test of create-agent-user.sh and verify.sh, for CI only.
#
# It breaks the agent's separation on purpose (sudo rules, privileged groups,
# an open home folder, a listener on all interfaces) and checks that verify.sh
# reports each one and create-agent-user.sh repairs it. That would be a bad
# thing to do to a real machine, so it refuses to run outside CI.
#
# Usage (GitHub Actions): sudo env CI="$CI" bash tests/integration.sh
set -euo pipefail

[[ ${CI:-} == true ]] || { echo "refusing to run outside CI (it grants sudo rights to a test user)" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ ! -f $ROOT/config.env ]] || { echo "config.env would override the test settings" >&2; exit 2; }

export AGENT_USER=sla-ci-agent
export OPENCLAW_PORT=18789
SUDOERS_FILE=/etc/sudoers.d/zz-sla-ci
listener=""
copies=""

cleanup() {
  rm -f "$SUDOERS_FILE"
  [[ -z $copies ]] || rm -rf -- "$copies"
  [[ -z $listener ]] || kill "$listener" 2>/dev/null || true
}
trap cleanup EXIT

n_ok=0 n_bad=0
out=""

step() { printf '\n=== %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; n_ok=$((n_ok + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; n_bad=$((n_bad + 1)); }

create() { "$ROOT/scripts/create-agent-user.sh" >/dev/null 2>&1; }
repair() { create || bad "create-agent-user.sh did not repair it"; }
verify() { out=$("$ROOT/scripts/verify.sh" 2>&1 || true); }

# expect STATUS TEXT: verify.sh printed a STATUS (PASS/WARN/FAIL) line containing TEXT
expect() {
  local line
  while IFS= read -r line; do
    if [[ $line == "  $1  "*"$2"* ]]; then ok "$1: $2"; return; fi
  done <<<"$out"
  bad "expected a $1 line containing '$2'. verify.sh said:"
  printf '%s\n' "$out" | sed 's/^/        | /'
}

# refuses TEXT [VAR=VALUE...] SCRIPT: SCRIPT --help stops with an error containing
# TEXT. Every script checks its settings before anything else, so with --help
# nothing would happen even if the check were missing.
refuses() {
  local text=$1 out
  shift
  if out=$(env "$@" --help 2>&1); then bad "accepted: $*"
  elif [[ $out == *"$text"* ]]; then ok "refused: $*"
  else bad "refused $*, but not with '$text': $out"; fi
}

# listen ADDR: start a dummy server on ADDR:OPENCLAW_PORT and wait until it is up
listen() {
  stop_listening
  python3 -m http.server --bind "$1" "$OPENCLAW_PORT" >/dev/null 2>&1 &
  listener=$!
  local _
  for _ in $(seq 50); do
    [[ -n $(ss -Hltn "sport = :$OPENCLAW_PORT") ]] && return
    sleep 0.1
  done
  echo "dummy listener on $1:$OPENCLAW_PORT did not start" >&2
  exit 1
}
stop_listening() {
  [[ -n $listener ]] || return 0
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
  listener=""
}

# --------------------------------------------------------------------------
step "fresh setup: create-agent-user.sh, then verify.sh"
if create; then ok "create-agent-user.sh succeeds"; else bad "create-agent-user.sh failed"; fi
if create; then ok "create-agent-user.sh succeeds again (idempotent)"; else bad "second run failed"; fi
verify
expect PASS "in no privileged group"
expect PASS "sudo grants it nothing"
expect PASS "password locked"
expect PASS "other users cannot look inside"
expect PASS "linger on"

step "settings that point at the wrong account or folder"
refuses "is root" AGENT_USER=root "$ROOT/scripts/uninstall.sh"
refuses "is root" AGENT_USER=root "$ROOT/scripts/create-agent-user.sh"
refuses "is root" COLIBRI_USER=root "$ROOT/scripts/uninstall.sh"
if [[ -n ${SUDO_USER:-} ]]; then
  refuses "your own account" AGENT_USER="$SUDO_USER" "$ROOT/scripts/create-agent-user.sh"
fi
refuses "system account" AGENT_USER=daemon "$ROOT/scripts/create-agent-user.sh"
refuses "not a valid user name" AGENT_USER="bad name" "$ROOT/scripts/verify.sh"
refuses "must be different" COLIBRI_USER="$AGENT_USER" "$ROOT/scripts/install-colibri-service.sh"
refuses "plain folder name" COLIBRI_STATE_NAME=.. "$ROOT/scripts/uninstall.sh"
if "$ROOT/scripts/uninstall.sh" --help >/dev/null 2>&1; then ok "accepted: the test settings"
else bad "the test settings were refused"; fi

step "a checkout the agent can change"
copies=$(mktemp -d)
chmod 755 "$copies"
mkdir -m 755 "$copies/parent"
copy=$copies/parent/sla
mkdir -m 755 "$copy"
cp -r "$ROOT/lib" "$ROOT/scripts" "$copy/"
chmod o+w "$copy/lib/common.sh"
refuses "can write $copy/lib/common.sh" "$copy/scripts/verify.sh"
chmod o-w "$copy/lib/common.sh"
chmod 777 "$copies/parent"
refuses "can write $copies/parent" "$copy/scripts/verify.sh"
chmod +t "$copies/parent"
if "$copy/scripts/verify.sh" --help >/dev/null 2>&1; then ok "accepted: a writable parent with the sticky bit"
else bad "refused a writable parent with the sticky bit"; fi

step "agent in the sudo group"
usermod -aG sudo "$AGENT_USER"
verify
expect FAIL "in privileged group(s): sudo"
repair
verify
expect PASS "in no privileged group"

step "agent has a sudoers rule"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$AGENT_USER" >"$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
visudo -cqf "$SUDOERS_FILE"
verify
expect FAIL "sudo grants it rules"
if create; then bad "create-agent-user.sh should refuse while a sudo rule exists"; else ok "create-agent-user.sh refuses while a sudo rule exists"; fi
rm -f "$SUDOERS_FILE"
verify
expect PASS "sudo grants it nothing"

step "agent has a password"
echo "$AGENT_USER:not-a-real-password" | chpasswd
verify
expect WARN "it has a password"
repair
verify
expect PASS "password locked"

step "agent's home is readable by others"
home=$(getent passwd "$AGENT_USER" | cut -d: -f6)
chmod 755 "$home"
verify
expect WARN "other users can read it"
repair
verify
expect PASS "other users cannot look inside"

step "linger off"
loginctl disable-linger "$AGENT_USER"
verify
expect FAIL "linger off"
repair
verify
expect PASS "linger on"

step "gateway port: loopback vs. all interfaces"
listen 0.0.0.0
verify
expect FAIL "Gateway is reachable from the network"
listen 127.0.0.1
verify
expect PASS "Gateway listens on loopback only"
stop_listening
verify
expect FAIL "Gateway: nothing listens on port"

# --------------------------------------------------------------------------
printf '\n%d ok, %d failed\n' "$n_ok" "$n_bad"
(( n_bad == 0 ))
