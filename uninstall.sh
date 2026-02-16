#!/usr/bin/env bash
set -euo pipefail

MT_DIR="${MT_DIR:-/opt/MTProxy}"
SERVICE_NAME="mtproxy"
SERVICE_FILE="/etc/systemd/system/mtproxy.service"
STATE_FILE="${STATE_FILE:-/etc/mtproxy-installer.env}"
RUN_USER="${RUN_USER:-mtproxy}"
ABUSE_MARKER="mtproxy_installer_abuse_protection"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
log(){ echo -e "[mtproxy] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[mtproxy] Run as root (or via sudo)." >&2; exit 1; }

PORT=""
if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE" || true
  PORT="${CLIENT_PORT:-}"
fi

log "Stopping and disabling service..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

log "Removing systemd unit..."
rm -f "$SERVICE_FILE" || true
systemctl daemon-reload 2>/dev/null || true

if [[ -n "$PORT" ]]; then
  if have_cmd nft; then
    nft list chain inet filter input >/dev/null 2>&1 || true
    while read -r handle; do
      [[ -n "$handle" ]] && nft delete rule inet filter input handle "$handle" || true
    done < <(nft -a list chain inet filter input 2>/dev/null | awk -v m="$ABUSE_MARKER" '$0 ~ m {print $NF}' || true)
  fi
  if have_cmd iptables; then
    iptables -D INPUT -p tcp --dport "$PORT" -j MTPROXY_ABUSE 2>/dev/null || true
    iptables -F MTPROXY_ABUSE 2>/dev/null || true
    iptables -X MTPROXY_ABUSE 2>/dev/null || true
  fi
fi

log "Removing directory: $MT_DIR"
rm -rf "$MT_DIR" || true

log "Removing state file: $STATE_FILE"
rm -f "$STATE_FILE" || true

if id -u "$RUN_USER" >/dev/null 2>&1; then
  log "Removing user: $RUN_USER"
  userdel "$RUN_USER" 2>/dev/null || true
fi

log "Done."
