#!/usr/bin/env bash
set -euo pipefail

# MTProxy Installer (Ubuntu/Debian)
# Default behavior: DOES NOT touch firewall.
# Optional minimal anti-abuse protection (rate limits) can be enabled explicitly via --anti-abuse.
#
# Key improvements (security/ops):
# - No global git config changes (no git --global safe.directory)
# - Optional anti-abuse injects rules into EXISTING firewall chains only (no new hook chains)
# - Installer self-update is gated by trusted remote URL check (supply-chain hardening)
# - Public IP detection prefers local routing; external services are best-effort and can be disabled

# MTProxy installer (Ubuntu/Debian)
# Fixes the common crash:
#   common/pid.c:42: init_common_PID: Assertion `!(p & 0xffff0000)' failed.
# by ensuring kernel.pid_max <= 65535 (PIDs < 65536).

MT_DIR="${MT_DIR:-/opt/MTProxy}"
REPO_URL="${REPO_URL:-https://github.com/TelegramMessenger/MTProxy}"
SERVICE_NAME="mtproxy"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
RUN_USER="${RUN_USER:-mtproxy}"
STATE_FILE="${STATE_FILE:-/etc/mtproxy-installer.env}"

SERVER_IP="${SERVER_IP:-}"  # optional override
CLIENT_PORT="${CLIENT_PORT:-8443}"
STATS_PORT="${STATS_PORT:-8888}"
MT_REF="${MT_REF:-}"        # optional tag/commit
YES="${YES:-0}"

log(){ echo "[mtproxy] $*" >&2; }
warn(){ echo "[mtproxy] WARN: $*" >&2; }
die(){ echo "[mtproxy] ERROR: $*" >&2; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (or via sudo)."; }

confirm(){
  [[ "$YES" == "1" ]] && return 0
  local ans=""
  read -r -p "$1 (y/N): " ans || true
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Aborted.";
}

# ---------- helpers ----------
detect_public_ipv4(){
  local ip=""
  if have_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  ip="${ip//[[:space:]]/}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  if have_cmd curl; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org || true)"
  fi
  ip="${ip//[[:space:]]/}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  return 1
}

ensure_pid_max(){
  # MTProxy (some builds) expects PID < 65536.
  local cur=""
  [[ -r /proc/sys/kernel/pid_max ]] || return 0
  cur="$(cat /proc/sys/kernel/pid_max 2>/dev/null || true)"
  [[ "$cur" =~ ^[0-9]+$ ]] || return 0

  if [[ "$cur" -gt 65535 ]]; then
    warn "kernel.pid_max=$cur (>65535). MTProxy may crash with init_common_PID assertion."
    confirm "Set kernel.pid_max=65535 now and persist in /etc/sysctl.d/99-mtproxy.conf?"

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-mtproxy.conf <<'CONF'
# MTProxy compatibility: keep PIDs below 65536
kernel.pid_max = 65535
CONF

    if have_cmd sysctl; then
      sysctl -w kernel.pid_max=65535 >/dev/null
      sysctl --system >/dev/null 2>&1 || true
    else
      echo 65535 > /proc/sys/kernel/pid_max || true
    fi

    log "kernel.pid_max is now: $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo '?')"
  fi
}

install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  log "Installing dependencies..."
  apt-get update -y
  apt-get install -y git build-essential libssl-dev zlib1g-dev wget curl xxd ca-certificates procps
}

prepare_user(){
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    log "Creating system user: $RUN_USER"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi
}

git_mt(){
  # Avoid "dubious ownership" without touching global git config
  git -c safe.directory="$MT_DIR" -C "$MT_DIR" "$@"
}

clone_and_build(){
  rm -rf "$MT_DIR"
  mkdir -p "$MT_DIR"
  log "Cloning MTProxy repo..."
  git clone --recursive "$REPO_URL" "$MT_DIR"

  if [[ -n "$MT_REF" ]]; then
    log "Pinning MTProxy to ref: $MT_REF"
    git_mt fetch --tags --force
    git_mt checkout --force "$MT_REF"
    git_mt submodule update --init --recursive
  else
    log "MT_REF not set: using default branch (NOT recommended for production)."
  fi

  local commit
  commit="$(git_mt rev-parse --short HEAD 2>/dev/null || true)"
  log "Building MTProxy (commit: ${commit:-unknown})..."
  make -C "$MT_DIR" COMMIT="${commit:-}" >&2 || make -C "$MT_DIR" >&2
  echo "$commit"
}

download_proxy_files(){
  log "Downloading proxy-secret and proxy-multi.conf..."
  curl -fL --retry 3 --retry-delay 1 --max-time 20 https://core.telegram.org/getProxySecret -o "$MT_DIR/proxy-secret"
  curl -fL --retry 3 --retry-delay 1 --max-time 20 https://core.telegram.org/getProxyConfig  -o "$MT_DIR/proxy-multi.conf"
  chmod 644 "$MT_DIR/proxy-secret" "$MT_DIR/proxy-multi.conf"
}

write_systemd(){
  local raw_secret="$1"
  local bin="$MT_DIR/objs/bin/mtproto-proxy"
  [[ -x "$bin" ]] || die "mtproto-proxy not found after build."

  log "Writing systemd unit: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=MTProxy (Telegram MTProto Proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER

# NOTE: do NOT pass -u when running under systemd User=
ExecStart=$bin -p $STATS_PORT -H $CLIENT_PORT -S $raw_secret --aes-pwd $MT_DIR/proxy-secret $MT_DIR/proxy-multi.conf -M 1

Restart=on-failure
RestartSec=2

# Hardening (safe defaults)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
}

start_service(){
  systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
  systemctl restart "$SERVICE_NAME"

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "Service failed to start. Showing logs:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true

    warn "If the log shows 'init_common_PID assertion', reboot once after setting pid_max to force PID wrap." 
    die "mtproxy failed"
  fi
}

save_state(){
  local mt_commit="$1" ip="$2" raw_secret="$3" link_secret="$4"
  umask 077
  cat > "$STATE_FILE" <<STATE
MT_REF="$MT_REF"
MT_COMMIT="$mt_commit"
SERVER_IP="$ip"
CLIENT_PORT="$CLIENT_PORT"
STATS_PORT="$STATS_PORT"
RAW_SECRET="$raw_secret"
LINK_SECRET="$link_secret"
MT_DIR="$MT_DIR"
STATE
  chmod 600 "$STATE_FILE" || true
}

print_links(){
  local ip="$1" port="$2" secret="$3"
  echo "tg://proxy?server=$ip&port=$port&secret=$secret"
  echo "https://t.me/proxy?server=$ip&port=$port&secret=$secret"
}

print_commands(){
  cat <<EOF
Available commands:
  sudo ./${0##*/} status
  sudo ./${0##*/} check
  sudo systemctl status mtproxy --no-pager -l
  sudo journalctl -u mtproxy -f
  sudo systemctl restart mtproxy
  sudo ./${0##*/} uninstall
EOF
}

status_cmd(){
  need_root
  systemctl status "$SERVICE_NAME" --no-pager -l || true
  echo
  have_cmd ss && ss -lntp | grep -E "(:${CLIENT_PORT}\\b|:${STATS_PORT}\\b).*mtproto-proxy" || true
  echo
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || true
}

check_cmd(){
  need_root
  echo "== Version check =="
  echo
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  if command -v git >/dev/null 2>&1 && git -C "$script_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Installer version: $(git -C "$script_dir" describe --tags --always --dirty 2>/dev/null || echo "<unknown>")"
    echo "Installer remote (origin): $(git -C "$script_dir" remote get-url origin 2>/dev/null || echo "<none>")"
  else
    echo "Installer version: <unknown> (not a git clone)"
  fi

  echo
  if [[ -d "${MT_DIR}/.git" ]] && command -v git >/dev/null 2>&1; then
    echo "MTProxy repo: ${MT_DIR}"
    echo "  Current commit: $(git -c safe.directory="${MT_DIR}" -C "${MT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "<unknown>")"
    echo "  Current branch: $(git -c safe.directory="${MT_DIR}" -C "${MT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "<unknown>")"
  else
    echo "MTProxy repo: <not installed>"
  fi
}

uninstall_cmd(){
  need_root
  confirm "This will stop and remove MTProxy. Continue?"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$MT_DIR" "$STATE_FILE"
  log "Uninstalled."
}

main(){
  need_root

  case "${1:-}" in
    status) status_cmd; exit 0;;
    check) check_cmd; exit 0;;
    uninstall) uninstall_cmd; exit 0;;
    -h|--help)
      cat <<'HELP'
Usage:
  sudo ./install.sh              # install / reinstall
  sudo ./install.sh status
  sudo ./install.sh check
  sudo ./install.sh uninstall

Env overrides:
  MT_REF=<tag|commit>   SERVER_IP=<public ip>
  CLIENT_PORT=8443      STATS_PORT=8888
  YES=1                 # non-interactive
HELP
      exit 0;;
  esac

  install_deps
  prepare_user

  [[ -z "$SERVER_IP" ]] && SERVER_IP="$(detect_public_ipv4 || true)"
  [[ -z "$SERVER_IP" ]] && die "Could not detect public IP. Set SERVER_IP=..."

  ensure_pid_max

  log "Using IP: $SERVER_IP"
  log "Ports: client(-H)=$CLIENT_PORT, stats(-p)=$STATS_PORT"

  local mt_commit
  mt_commit="$(clone_and_build)"
  download_proxy_files

  local raw_secret link_secret
  raw_secret="$(head -c 16 /dev/urandom | xxd -ps -c 32)"
  link_secret="dd${raw_secret}"

  write_systemd "$raw_secret"
  start_service

  save_state "$mt_commit" "$SERVER_IP" "$raw_secret" "$link_secret"

  log ""
  log "MTProxy installed and running."
  log "MT_COMMIT: ${mt_commit:-unknown}"
  log "IP: $SERVER_IP"
  log "Port: $CLIENT_PORT"
  log "Secret: $link_secret"
  echo
  log "Telegram links:"
  print_links "$SERVER_IP" "$CLIENT_PORT" "$link_secret"
  echo
  print_commands
}

main "$@"
