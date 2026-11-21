#!/usr/bin/env bash
# Run SearXNG (web search for the agent) as a Podman Quadlet: started at boot,
# on loopback only, in its own user namespace. Then point OpenClaw at it.
# Safe to run again: the settings file and its secret are kept.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [--no-openclaw]
       $0 --print-unit

  (no option)    write $SEARXNG_CONFIG_DIR/settings.yml (JSON on, limiter off),
                 install the Quadlet $SEARXNG_UNIT.container, start it, check it
                 answers on 127.0.0.1:$SEARXNG_PORT, then install OpenClaw's
                 searxng plugin for $AGENT_USER and make it the web search
  --no-openclaw  leave OpenClaw alone
  --print-unit   only print the Quadlet that would be installed (no root needed)
EOF
}

openclaw=yes print_only=no
case ${1:-} in
  "") ;;
  --no-openclaw) openclaw=no ;;
  --print-unit)  print_only=yes ;;
  -h|--help)     usage; exit 0 ;;
  *)             usage >&2; die "unknown option: $1" ;;
esac

settings=$SEARXNG_CONFIG_DIR/settings.yml
quadlet=/etc/containers/systemd/$SEARXNG_UNIT.container
url="http://127.0.0.1:$SEARXNG_PORT"

render_unit() {
  local v
  for v in "$SEARXNG_UNIT" "$SEARXNG_IMAGE" "$SEARXNG_PORT" "$SEARXNG_CONFIG_DIR"; do
    case $v in *'|'* | *'&'* | *\\* | *$'\n'*) die "unsupported character (| & \\ or newline) in setting: $v" ;; esac
  done
  sed -e "s|@UNIT@|$SEARXNG_UNIT|g" \
      -e "s|@IMAGE@|$SEARXNG_IMAGE|g" \
      -e "s|@PORT@|$SEARXNG_PORT|g" \
      -e "s|@CONFIG_DIR@|$SEARXNG_CONFIG_DIR|g" \
      "$SLA_ROOT/systemd/searxng.container.in"
}

if [[ $print_only == yes ]]; then
  render_unit
  exit 0
fi

need_root
need_cmd podman curl openssl systemctl
[[ -x /usr/libexec/podman/quadlet || -x /usr/lib/podman/quadlet ]] || die "Podman's Quadlet is missing (needs Podman 4.4 or newer)"

# Docker sets the kernel's FORWARD policy to DROP. That also drops Podman's
# container traffic, SearXNG can't reach the internet, and it exits at start.
if systemctl -q is-active docker.service 2>/dev/null; then
  die "Docker is running; its firewall rules block Podman containers. Stop and disable it (systemctl disable --now docker.service docker.socket), reboot, and run this again."
fi
if command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q 'chain DOCKER'; then
  die "Docker's firewall rules are still loaded and block Podman containers. Reboot (with Docker disabled) and run this again."
fi

# Settings: JSON for OpenClaw, no rate limiter (only local clients), no image
# proxy. Readable by all: the container's mapped user must read it, and the
# secret only signs SearXNG's own cookies and links.
if [[ -f $settings ]]; then
  log "keeping $settings"
  grep -qE '^[[:space:]]*formats:.*json' "$settings" \
    || warn "$settings does not seem to enable the json format; OpenClaw's searches will get 403"
else
  log "writing $settings"
  install -d -m 755 "$SEARXNG_CONFIG_DIR"
  (umask 022; cat >"$settings" <<EOF
use_default_settings: true
server:
  secret_key: "$(openssl rand -hex 32)"
  limiter: false
  image_proxy: false
search:
  formats: [html, json]
EOF
  )
  chmod 644 "$settings"
fi

# UserNS=auto takes its UIDs from the range of the (pseudo) user "containers"
for f in /etc/subuid /etc/subgid; do
  if ! grep -qs '^containers:' "$f"; then
    echo "containers:2147483647:2147483648" >>"$f"
    log "added the 'containers' ID range to $f (for UserNS=auto)"
  fi
done

new=$(render_unit)
if [[ -f $quadlet && $(<"$quadlet") == "$new" ]]; then
  log "$quadlet is up to date"
else
  install -d -m 755 "$(dirname -- "$quadlet")"
  printf '%s\n' "$new" >"$quadlet"
  chmod 644 "$quadlet"
  log "installed $quadlet"
fi
systemctl daemon-reload
log "starting $SEARXNG_UNIT (the first start downloads the image)"
systemctl restart "$SEARXNG_UNIT"

code=000
for _ in $(seq 60); do
  code=$(http_code "$url/search?q=test&format=json")
  [[ $code == 200 ]] && break
  sleep 2
done
[[ $code == 200 ]] || die "SearXNG does not answer on $url (last HTTP status $code). Check: journalctl -u $SEARXNG_UNIT -n 40"
log "SearXNG answers on $url"

if [[ $openclaw == no ]]; then
  log "done (OpenClaw left alone)"
  exit 0
fi
user_exists "$AGENT_USER" || die "user $AGENT_USER does not exist; run again with --no-openclaw, or install the agent first"
home=$(home_of "$AGENT_USER")
[[ -f $home/.openclaw/openclaw.json ]] || die "no OpenClaw config for $AGENT_USER yet: run install-openclaw.sh first, or use --no-openclaw"

if [[ -d $home/.openclaw/extensions/searxng ]]; then
  log "OpenClaw's searxng plugin is already installed"
else
  log "installing @openclaw/searxng-plugin@$OPENCLAW_VERSION for $AGENT_USER (adds it to plugins.allow)"
  oc plugins install "@openclaw/searxng-plugin@$OPENCLAW_VERSION" </dev/null
fi
oc config set tools.web.search.provider searxng >/dev/null || die "OpenClaw refused tools.web.search.provider"
oc config set plugins.entries.searxng.config.webSearch.baseUrl "$url" >/dev/null || die "OpenClaw refused the SearXNG URL"
oc gateway restart >/dev/null || warn "gateway restart failed: sudo -iu $AGENT_USER openclaw gateway status"

cat <<EOF

${C_B}Done.${C_OFF} SearXNG runs as $SEARXNG_UNIT.service on $url and is the agent's web search.
  log      journalctl -u $SEARXNG_UNIT -f
  test     ask the agent to search the web for something
  check    sudo $SLA_ROOT/scripts/verify.sh
EOF
