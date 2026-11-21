#!/usr/bin/env bash
# Remove what the other scripts set up. Nothing happens without an option.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [--openclaw] [--colibri [--purge-colibri]] [--searxng] [--agent-user] [--yes]

  --openclaw       remove the gateway service and the openclaw package from $AGENT_USER
                   (keeps ~$AGENT_USER/.openclaw: config, sessions, workspace)
  --colibri        stop and remove the $COLIBRI_UNIT service (keeps the model copy and key)
  --purge-colibri  with --colibri: also delete $COLIBRI_STATE_DIR, $COLIBRI_KEY_FILE
                   and the $COLIBRI_USER user
  --searxng        stop and remove the $SEARXNG_UNIT Quadlet (keeps $SEARXNG_CONFIG_DIR and the image)
  --agent-user     delete the user $AGENT_USER AND ITS HOME FOLDER
  --yes            do not ask before deleting data
EOF
}

do_openclaw=no do_colibri=no purge=no do_searxng=no do_user=no yes=no
[[ $# -gt 0 ]] || { usage; exit 0; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --openclaw)      do_openclaw=yes ;;
    --colibri)       do_colibri=yes ;;
    --purge-colibri) purge=yes ;;
    --searxng)       do_searxng=yes ;;
    --agent-user)    do_user=yes ;;
    --yes)           yes=yes ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
[[ $purge == no || $do_colibri == yes ]] || die "--purge-colibri needs --colibri"
need_root

confirm() {
  [[ $yes == yes ]] && return 0
  local answer
  read -rp "$1 Type 'yes' to continue: " answer
  [[ $answer == yes ]] || die "cancelled"
}

if [[ $do_openclaw == yes || $do_user == yes ]] && user_exists "$AGENT_USER"; then
  log "removing the OpenClaw gateway service from $AGENT_USER"
  as_user "$AGENT_USER" openclaw gateway uninstall || warn "openclaw gateway uninstall failed (maybe not installed)"
  if [[ $do_openclaw == yes ]]; then
    as_user "$AGENT_USER" npm uninstall -g openclaw || true
    log "openclaw removed; config kept in $(home_of "$AGENT_USER")/.openclaw"
  fi
fi

if [[ $do_colibri == yes ]]; then
  log "removing the $COLIBRI_UNIT service"
  systemctl disable --now "$COLIBRI_UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$COLIBRI_UNIT.service"
  systemctl daemon-reload
  if [[ $purge == yes ]]; then
    confirm "This deletes $COLIBRI_STATE_DIR (the model copy) and $COLIBRI_KEY_FILE."
    rm -rf -- "$COLIBRI_STATE_DIR" "$COLIBRI_KEY_FILE"
    rmdir --ignore-fail-on-non-empty "$(dirname -- "$COLIBRI_KEY_FILE")" 2>/dev/null || true
    user_exists "$COLIBRI_USER" && userdel "$COLIBRI_USER"
    log "purged Colibri service data and user"
  fi
fi

if [[ $do_searxng == yes ]]; then
  log "removing the $SEARXNG_UNIT Quadlet"
  systemctl stop "$SEARXNG_UNIT" 2>/dev/null || true
  rm -f "/etc/containers/systemd/$SEARXNG_UNIT.container"
  systemctl daemon-reload
  log "removed; kept $SEARXNG_CONFIG_DIR and the image (podman rmi to delete it)"
  if user_exists "$AGENT_USER"; then
    log "the agent's web search still points at it: sudo -iu $AGENT_USER openclaw config unset tools.web.search.provider"
  fi
fi

if [[ $do_user == yes ]] && user_exists "$AGENT_USER"; then
  confirm "This deletes the user $AGENT_USER and everything in $(home_of "$AGENT_USER")."
  loginctl disable-linger "$AGENT_USER" || true
  loginctl terminate-user "$AGENT_USER" 2>/dev/null || true
  pkill -u "$AGENT_USER" 2>/dev/null || true
  sleep 1
  results=${RESEARCH_DIR:-$(home_of "$AGENT_USER")/research}
  if command -v semanage >/dev/null; then semanage fcontext -d "$results(/.*)?" 2>/dev/null || true; fi
  userdel -r "$AGENT_USER"
  log "deleted user $AGENT_USER"
fi
