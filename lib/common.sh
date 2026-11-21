# shellcheck shell=bash
# shellcheck disable=SC2034  # settings and colors are used by the scripts that source this
# Shared settings and helpers for the safe-local-agent scripts.
# Sourced by the scripts in scripts/, not run on its own.

SLA_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Settings: config.env (if present) first, then these defaults for anything unset.
if [[ -f "$SLA_ROOT/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$SLA_ROOT/config.env"
fi

: "${AGENT_USER:=mrdata}"
: "${COLIBRI_USER:=colibri}"
: "${COLIBRI_UNIT:=colibri}"
: "${COLIBRI_DIR:=/opt/colibri}"
: "${COLIBRI_STATE_NAME:=colibri}"
: "${COLIBRI_MODEL_SRC:=}"
: "${COLIBRI_HOST:=127.0.0.1}"
: "${COLIBRI_PORT:=8000}"
: "${COLIBRI_GPU:=auto}"
: "${COLIBRI_EXTRA_ARGS:=--auto-tier}"
: "${COLIBRI_REQUIRE_KEY:=yes}"
: "${COLIBRI_KEY_FILE:=/etc/colibri/colibri.env}"
: "${OLLAMA_UNIT:=ollama}"
: "${OLLAMA_PORT:=11434}"
: "${OPENCLAW_VERSION:=2026.11.6}"
: "${OPENCLAW_PORT:=18789}"
: "${OPENCLAW_UNIT:=openclaw-gateway}"
: "${PONYTAIL:=no}"
: "${PONYTAIL_REF:=96608e078b2d5ea607c5c3b8b5a54d1c1fba6846}"
: "${PRIVILEGED_GROUPS:=wheel sudo admin docker podman libvirt lxd incus disk adm systemd-journal ollama}"

COLIBRI_STATE_DIR=/var/lib/$COLIBRI_STATE_NAME

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m' C_DIM=$'\e[2m' C_B=$'\e[1m' C_OFF=$'\e[0m'
else
  C_RED='' C_GRN='' C_YEL='' C_BLU='' C_DIM='' C_B='' C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
warn() { printf '%sWARN:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run this as root: sudo $0"; }
need_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "missing command: $c"; done
}

user_exists() { getent passwd "$1" >/dev/null; }
home_of()     { getent passwd "$1" | cut -d: -f6; }
# in_group USER GROUP (no pipes: grep -q + pipefail gives false negatives)
in_group()    { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }

# privileged_groups_of USER: prints the user's groups that are in PRIVILEGED_GROUPS
privileged_groups_of() {
  local g p
  for g in $(id -nG "$1" 2>/dev/null); do
    for p in $PRIVILEGED_GROUPS; do
      [[ $g == "$p" ]] && printf '%s\n' "$g"
    done
  done
  return 0
}

# as_user USER CMD...: run a command as USER (root only) with a clean
# environment, in USER's home, connected to USER's systemd --user instance.
as_user() {
  local u=$1 uid home
  shift
  uid=$(id -u "$u")
  home=$(home_of "$u")
  runuser -u "$u" -- env -i -C "$home" \
    HOME="$home" USER="$u" LOGNAME="$u" SHELL=/bin/bash \
    PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    TERM="${TERM:-xterm}" LANG="${LANG:-C.UTF-8}" \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$@"
}

# read_key: prints the Colibri API key from COLIBRI_KEY_FILE (root only)
read_key() {
  [[ -r $COLIBRI_KEY_FILE ]] || return 1
  sed -n 's/^COLI_API_KEY=//p' "$COLIBRI_KEY_FILE" | head -n 1
}

# curl_auth KEY CURL-ARGS...: the key goes in through stdin, never on the command line
curl_auth() {
  local key=$1
  shift
  if [[ -n $key ]]; then
    printf 'Authorization: Bearer %s\n' "$key" | curl -s --max-time 10 -H @- "$@"
  else
    curl -s --max-time 10 "$@"
  fi
}

# http_code URL [KEY]: prints the HTTP status, 000 if nothing answers
http_code() { curl_auth "${2:-}" -o /dev/null -w '%{http_code}' "$1" || true; }

# listen_addrs PORT: local addresses with a TCP listener on PORT
listen_addrs() { ss -Hltn "sport = :$1" 2>/dev/null | awk '{print $4}'; }

is_loopback_addr() { [[ $1 == 127.* || $1 == "[::1]:"* || $1 == "[::ffff:127."* ]]; }
is_loopback_host() { [[ $1 == 127.* || $1 == localhost || $1 == ::1 ]]; }

# extract_openclaw_key PORT: python that prints the apiKey of the OpenClaw
# provider pointing at a local PORT (run as the agent user, reads its config)
OPENCLAW_PROVIDER_PY='
import json, os, sys
port = sys.argv[1]
path = os.path.expanduser("~/.openclaw/openclaw.json")
cfg = json.load(open(path))
for name, p in cfg.get("models", {}).get("providers", {}).items():
    url = str(p.get("baseUrl", ""))
    if any(url.startswith(f"http://{h}:{port}") for h in ("127.0.0.1", "localhost", "[::1]")):
        print(p.get("apiKey", ""))
        break
'
