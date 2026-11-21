#!/usr/bin/env bash
# Run Colibri as a hardened system service under its own user.
# Safe to run again: existing model copy and API key are kept.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 [--model DIR] [--enable] [--recopy]
       $0 --print-unit [--model DIR]

  --model DIR    model directory to serve (default: COLIBRI_MODEL_SRC in config.env)
  --enable       enable the service and start it now
  --recopy       copy the model again even if a copy exists
  --print-unit   only print the systemd unit that would be installed (no root needed)
EOF
}

model_src=$COLIBRI_MODEL_SRC enable=no recopy=no print_only=no
while [[ $# -gt 0 ]]; do
  case $1 in
    --model)      model_src=${2:?--model needs a directory}; shift 2 ;;
    --enable)     enable=yes; shift ;;
    --recopy)     recopy=yes; shift ;;
    --print-unit) print_only=yes; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown option: $1" ;;
  esac
done

[[ -n $model_src ]] || { usage >&2; die "no model given (--model DIR, or COLIBRI_MODEL_SRC in config.env)"; }
model_src=$(realpath -m -- "$model_src")
model_name=$(basename -- "$model_src")
[[ -n $model_name && $model_name != "/" && $model_name != "." && $model_name != ".." ]] || die "bad model directory: $model_src"
model_dir=$COLIBRI_STATE_DIR/models/$model_name
python_bin=$(command -v python3 || echo /usr/bin/python3)

render_unit() {
  local v
  for v in "$COLIBRI_USER" "$COLIBRI_DIR" "$COLIBRI_STATE_NAME" "$model_dir" "$COLIBRI_HOST" \
           "$COLIBRI_PORT" "$COLIBRI_GPU" "$COLIBRI_EXTRA_ARGS" "$COLIBRI_KEY_FILE" "$python_bin"; do
    case $v in *'|'* | *'&'* | *\\* | *$'\n'*) die "unsupported character (| & \\ or newline) in setting: $v" ;; esac
  done
  sed -e "s|@COLIBRI_USER@|$COLIBRI_USER|g" \
      -e "s|@COLIBRI_DIR@|$COLIBRI_DIR|g" \
      -e "s|@STATE_DIR@|$COLIBRI_STATE_DIR|g" \
      -e "s|@STATE_NAME@|$COLIBRI_STATE_NAME|g" \
      -e "s|@MODEL_DIR@|$model_dir|g" \
      -e "s|@HOST@|$COLIBRI_HOST|g" \
      -e "s|@PORT@|$COLIBRI_PORT|g" \
      -e "s|@GPU@|$COLIBRI_GPU|g" \
      -e "s|@EXTRA_ARGS@|$COLIBRI_EXTRA_ARGS|g" \
      -e "s|@KEY_FILE@|$COLIBRI_KEY_FILE|g" \
      -e "s|@PYTHON@|$python_bin|g" \
      "$SLA_ROOT/systemd/colibri.service.in"
}

if [[ $print_only == yes ]]; then
  render_unit
  exit 0
fi

need_root
need_cmd useradd usermod runuser systemctl install cp realpath curl ss od
[[ -f $COLIBRI_DIR/c/coli ]] || die "Colibri not found: expected $COLIBRI_DIR/c/coli (set COLIBRI_DIR)"
[[ -f $model_src/config.json ]] || die "$model_src does not look like a Colibri model directory (no config.json)"
is_loopback_host "$COLIBRI_HOST" || warn "COLIBRI_HOST=$COLIBRI_HOST is not loopback: the model API will be reachable from the network"

owner=$(stat -c %U "$COLIBRI_DIR")
[[ $owner == root ]] || warn "$COLIBRI_DIR is owned by '$owner', who can change the code this service runs. Root-owned is safer: chown -R root:root $COLIBRI_DIR"
if user_exists "$AGENT_USER" && runuser -u "$AGENT_USER" -- test -w "$COLIBRI_DIR/c/coli"; then
  die "the agent user $AGENT_USER can modify $COLIBRI_DIR/c/coli. Fix the permissions first."
fi

# 1. System user
if user_exists "$COLIBRI_USER"; then
  log "user $COLIBRI_USER exists"
else
  log "creating system user $COLIBRI_USER"
  useradd --system --user-group --home-dir "$COLIBRI_STATE_DIR" --no-create-home \
          --shell "$(command -v nologin || echo /usr/sbin/nologin)" "$COLIBRI_USER"
fi
for g in render video; do
  if getent group "$g" >/dev/null && ! in_group "$COLIBRI_USER" "$g"; then
    usermod -aG "$g" "$COLIBRI_USER"
    log "added $COLIBRI_USER to '$g' (GPU device access)"
  fi
done

# 2. Model copy the service user owns (ProtectHome keeps it out of /home)
install -d -o "$COLIBRI_USER" -g "$COLIBRI_USER" -m 750 "$COLIBRI_STATE_DIR" "$COLIBRI_STATE_DIR/models"
if [[ -d $model_dir && $recopy == no ]]; then
  log "model copy exists: $model_dir (--recopy to refresh it)"
else
  log "copying $model_src to $model_dir (instant reflink on btrfs/XFS, a full copy elsewhere)"
  rm -rf -- "$model_dir.tmp"
  cp -a --reflink=auto -- "$model_src" "$model_dir.tmp"
  rm -rf -- "$model_dir"
  mv -- "$model_dir.tmp" "$model_dir"
fi
chown -R "$COLIBRI_USER:$COLIBRI_USER" "$COLIBRI_STATE_DIR"
chmod -R u+rwX,g+rX,g-w,o-rwx "$COLIBRI_STATE_DIR"
if command -v selinuxenabled >/dev/null && selinuxenabled && command -v restorecon >/dev/null; then
  restorecon -R "$COLIBRI_STATE_DIR"
fi

# 3. API key
if [[ $COLIBRI_REQUIRE_KEY == yes ]]; then
  if [[ -f $COLIBRI_KEY_FILE ]]; then
    log "API key file exists: $COLIBRI_KEY_FILE"
  else
    log "generating an API key in $COLIBRI_KEY_FILE"
    install -d -m 755 "$(dirname -- "$COLIBRI_KEY_FILE")"
    (umask 077; printf 'COLI_API_KEY=%s\n' "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')" > "$COLIBRI_KEY_FILE")
  fi
  chown "root:$COLIBRI_USER" "$COLIBRI_KEY_FILE"
  chmod 640 "$COLIBRI_KEY_FILE"
else
  warn "COLIBRI_REQUIRE_KEY=no: every local user, the agent's tools included, can use the model API"
fi

# 4. Unit
unit_path=/etc/systemd/system/$COLIBRI_UNIT.service
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
render_unit > "$tmp"
if [[ -f $unit_path ]] && ! cmp -s "$tmp" "$unit_path"; then
  cp -- "$unit_path" "$unit_path.bak.$(date +%Y%m%d%H%M%S)"
  log "backed up the previous $unit_path"
fi
install -m 644 "$tmp" "$unit_path"
systemd-analyze verify "$unit_path" || warn "systemd-analyze reported the problems above"
systemctl daemon-reload
log "installed $unit_path"

# 5. Start
if [[ $enable != yes ]]; then
  echo
  log "done. Start it with: sudo systemctl enable --now $COLIBRI_UNIT"
  exit 0
fi

if [[ -n $(listen_addrs "$COLIBRI_PORT") ]] && ! systemctl -q is-active "$COLIBRI_UNIT"; then
  die "port $COLIBRI_PORT is already in use. Stop the Colibri you started by hand (Ctrl+C or: coli stop), then run this again."
fi
systemctl enable -q "$COLIBRI_UNIT"
systemctl restart "$COLIBRI_UNIT"
log "waiting for the model to load (up to 5 minutes; follow along with: journalctl -u $COLIBRI_UNIT -f)"
for _ in $(seq 150); do
  if [[ $(http_code "http://$COLIBRI_HOST:$COLIBRI_PORT/health") == 200 ]]; then
    echo
    log "Colibri is up: http://$COLIBRI_HOST:$COLIBRI_PORT/v1"
    log "next: sudo $SLA_ROOT/scripts/install-openclaw.sh"
    exit 0
  fi
  systemctl -q is-active "$COLIBRI_UNIT" || die "the service stopped. See: journalctl -u $COLIBRI_UNIT -n 50"
  sleep 2
done
warn "still not answering after 5 minutes. Large models can take longer; check: journalctl -u $COLIBRI_UNIT -f"
