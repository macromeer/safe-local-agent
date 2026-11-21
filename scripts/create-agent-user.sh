#!/usr/bin/env bash
# Create (or tighten) the unprivileged account the agent runs as.
# Safe to run again: it only fixes what is not already right.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

case ${1:-} in
  -h|--help)
    cat <<EOF
Usage: sudo $0

Creates the user AGENT_USER (now: $AGENT_USER) if needed, then:
  - locks its password (reach it with: sudo -iu $AGENT_USER)
  - removes it from privileged groups: $PRIVILEGED_GROUPS
  - sets its home to 700
  - checks that sudo grants it nothing
  - enables linger, so its services run without a login
  - warns about home folders other users can read
EOF
    exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (see --help)" ;;
esac

need_root
need_cmd useradd usermod gpasswd loginctl id getent

if user_exists "$AGENT_USER"; then
  log "user $AGENT_USER exists"
else
  log "creating user $AGENT_USER"
  useradd --create-home --user-group --shell /bin/bash "$AGENT_USER"
fi

usermod -L "$AGENT_USER"
log "password locked: nobody can log in as $AGENT_USER directly"

while IFS= read -r g; do
  [[ -n $g ]] || continue
  gpasswd -d "$AGENT_USER" "$g" >/dev/null
  log "removed $AGENT_USER from privileged group '$g'"
done < <(privileged_groups_of "$AGENT_USER")
log "groups of $AGENT_USER: $(id -nG "$AGENT_USER")"

home=$(home_of "$AGENT_USER")
chmod 700 "$home"
log "$home is 700"

if command -v sudo >/dev/null; then
  out=$(LC_ALL=C sudo -n -l -U "$AGENT_USER" 2>&1 || true)
  if grep -qi "not allowed" <<<"$out"; then
    log "sudo grants $AGENT_USER nothing"
  else
    printf '%s\n' "$out" >&2
    die "sudo grants $AGENT_USER the rules above. Remove them (visudo, /etc/sudoers.d) and run this again."
  fi
fi

loginctl enable-linger "$AGENT_USER"
uid=$(id -u "$AGENT_USER")
for _ in $(seq 20); do
  [[ -S /run/user/$uid/bus ]] && break
  sleep 0.5
done
if [[ -S /run/user/$uid/bus ]]; then
  log "linger on, systemd --user for $AGENT_USER is running"
else
  warn "linger is on but systemd --user for $AGENT_USER is not up yet; installing the OpenClaw service may fail"
fi

while IFS= read -r d; do
  warn "$d can be read by other users, so also by the agent. Fix with: chmod 700 $d"
done < <(find /home -mindepth 1 -maxdepth 1 -type d -perm /o=rx ! -path "$home" 2>/dev/null)

echo
log "done. Next: sudo $SLA_ROOT/scripts/install-colibri-service.sh --model <model dir> --enable"
