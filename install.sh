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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SELF_UPDATE="${INSTALLER_SELF_UPDATE:-1}"
INSTALLER_REMOTE="${INSTALLER_REMOTE:-origin}"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-}"
# Trusted remote URL for self-update (set this to your repo URL after you publish)
INSTALLER_TRUSTED_REMOTE_URL="${INSTALLER_TRUSTED_REMOTE_URL:-}"  # empty => self-update disabled unless explicitly trusted
INSTALLER_ALLOW_UNTRUSTED_REMOTE="${INSTALLER_ALLOW_UNTRUSTED_REMOTE:-0}" # 1 => allow self-update even if URL mismatch
YES="${YES:-0}"

MT_DIR="${MT_DIR:-/opt/MTProxy}"
REPO_URL="${REPO_URL:-https://github.com/TelegramMessenger/MTProxy}"
SERVICE_NAME="mtproxy"
SERVICE_UNIT="${SERVICE_NAME}.service"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_UNIT}}"
RUN_USER="${RUN_USER:-mtproxy}"
STATE_FILE="${STATE_FILE:-/etc/mtproxy-installer.env}"

MT_REF="${MT_REF:-}"
ACTION="${ACTION:-}"

# Firewall / anti-abuse: OFF by default
ANTI_ABUSE="${ANTI_ABUSE:-0}"             # 1 enabled via --anti-abuse
ABUSE_BACKEND_PREFERRED="${ABUSE_BACKEND_PREFERRED:-auto}"  # auto|nft|iptables
NEW_CONNS_PER_SEC="${NEW_CONNS_PER_SEC:-30}"
BURST_NEW_CONNS="${BURST_NEW_CONNS:-60}"
MAX_CONNS_PER_IP="${MAX_CONNS_PER_IP:-0}"  # iptables-only; 0=disabled

# IP detection
SERVER_IP="${SERVER_IP:-}"
NO_EXTERNAL_IP_LOOKUP="${NO_EXTERNAL_IP_LOOKUP:-0}" # 1 => do not query external IP services
CLIENT_PORT="${CLIENT_PORT:-}"
STATS_PORT="${STATS_PORT:-}"

CANDIDATE_CLIENT_PORTS=(8443 9443 10443 12443 23443 32443 41443)
CANDIDATE_STATS_PORTS=(8888 8889 8890 18080 19080 28080)

ABUSE_MARKER="mtproxy_installer_abuse_protection"
ABUSE_BACKEND="none"

log(){ echo -e "[mtproxy] $*"; }
warn(){ echo -e "[mtproxy] WARN: $*" >&2; }
die(){ echo -e "[mtproxy] ERROR: $*" >&2; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (or via sudo)."; }

service_installed(){
  systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${SERVICE_UNIT}"
}
service_active(){ systemctl is-active --quiet "${SERVICE_NAME}"; }

is_tty(){ [[ -t 0 && -t 1 ]]; }

confirm(){
  local prompt="$1"
  [[ "${YES}" == "1" ]] && return 0
  if ! is_tty; then
    die "Non-interactive mode: confirmation required. Re-run with --yes (or YES=1)."
  fi
  local ans=""
  read -r -p "$prompt (y/N): " ans || true
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Aborted by user."
}

is_tcp_port_free(){
  local p="$1"
  if have_cmd ss; then
    ss -lnt "( sport = :$p )" 2>/dev/null | grep -q ":$p" && return 1 || return 0
  elif have_cmd netstat; then
    netstat -lnt 2>/dev/null | grep -q ":$p " && return 1 || return 0
  else
    return 0
  fi
}

pick_free_port(){
  local -n arr=$1
  for p in "${arr[@]}"; do
    if is_tcp_port_free "$p"; then echo "$p"; return 0; fi
  done
  return 1
}

detect_local_ipv4(){
  if have_cmd ip; then
    local ipaddr
    ipaddr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    ipaddr="$(echo "$ipaddr" | tr -d '[:space:]')"
    [[ "$ipaddr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ipaddr"; return 0; }
  fi
  return 1
}

detect_public_ipv4_external(){
  [[ "$NO_EXTERNAL_IP_LOOKUP" == "1" ]] && return 1
  local ip=""
  if have_cmd curl; then
    ip="$(curl -fsS --max-time 3 https://api.ipify.org || true)"
    [[ -z "$ip" ]] && ip="$(curl -fsS --max-time 3 https://icanhazip.com || true)"
    [[ -z "$ip" ]] && ip="$(curl -fsS --max-time 3 https://ifconfig.me/ip || true)"
  fi
  ip="$(echo "$ip" | tr -d '[:space:]')"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  return 1
}

detect_public_ipv4(){
  detect_local_ipv4 && return 0
  detect_public_ipv4_external && return 0
  return 1
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
  sudo systemctl status ${SERVICE_NAME} --no-pager -l
  sudo journalctl -u ${SERVICE_NAME} -f
  sudo systemctl restart ${SERVICE_NAME}
  sudo ./uninstall.sh
EOF
}

git_mt(){
  git -c safe.directory="${MT_DIR}" -C "${MT_DIR}" "$@"
}

trusted_remote_ok(){
  [[ -d "${SCRIPT_DIR}/.git" ]] || return 1
  have_cmd git || return 1
  local url
  url="$(git -C "$SCRIPT_DIR" remote get-url "$INSTALLER_REMOTE" 2>/dev/null || true)"
  [[ -n "$url" ]] || return 1

  if [[ "${INSTALLER_ALLOW_UNTRUSTED_REMOTE}" == "1" ]]; then
    return 0
  fi

  if [[ -z "${INSTALLER_TRUSTED_REMOTE_URL}" ]]; then
    warn "Self-update is disabled: INSTALLER_TRUSTED_REMOTE_URL is not set."
    warn "Set it to your published repo URL to enable self-update safely."
    return 1
  fi

  if [[ "$url" != "${INSTALLER_TRUSTED_REMOTE_URL}" ]]; then
    warn "Self-update blocked: remote URL mismatch."
    warn "  Expected: ${INSTALLER_TRUSTED_REMOTE_URL}"
    warn "  Current:  ${url}"
    warn "Set INSTALLER_TRUSTED_REMOTE_URL correctly or set INSTALLER_ALLOW_UNTRUSTED_REMOTE=1 to override."
    return 1
  fi
  return 0
}

self_update_if_possible(){
  [[ "${INSTALLER_SELF_UPDATE}" == "1" ]] || return 0
  [[ "${SELF_UPDATED:-0}" == "1" ]] && return 0
  [[ -d "${SCRIPT_DIR}/.git" ]] || return 0
  have_cmd git || return 0

  trusted_remote_ok || return 0

  local branch=""
  branch="${INSTALLER_BRANCH:-$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
  [[ -n "$branch" ]] || return 0

  log "Self-update: checking installer repo (${INSTALLER_REMOTE}/${branch})..."
  git -C "$SCRIPT_DIR" fetch --prune "$INSTALLER_REMOTE" "$branch" >/dev/null 2>&1 || return 0

  local local_sha remote_sha
  local_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
  remote_sha="$(git -C "$SCRIPT_DIR" rev-parse "${INSTALLER_REMOTE}/${branch}")"
  if [[ "$local_sha" != "$remote_sha" ]]; then
    log "Self-update: updating installer to latest (${remote_sha:0:7})..."
    git -C "$SCRIPT_DIR" pull --rebase "$INSTALLER_REMOTE" "$branch"
    log "Self-update: re-executing updated installer."
    SELF_UPDATED=1 exec "$SCRIPT_DIR/${0##*/}" "$@"
  else
    log "Self-update: installer is up to date."
  fi
}

installer_version(){
  if [[ -d "${SCRIPT_DIR}/.git" ]] && have_cmd git; then
    git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || true
  fi
}

nft_can_use_existing_input(){ nft list chain inet filter input >/dev/null 2>&1; }

apply_abuse_nft_existing(){
  local port="$1"
  nft_can_use_existing_input || die "nftables 'inet filter input' chain not found. Configure your firewall first or use iptables backend."
  local c1="${ABUSE_MARKER}_syn_rate"
  local c2="${ABUSE_MARKER}_accept_port"

  nft list chain inet filter input | grep -q "$c1" ||     nft add rule inet filter input tcp dport $port tcp flags syn ct state new       limit rate over ${NEW_CONNS_PER_SEC}/second burst ${BURST_NEW_CONNS} packets drop comment "$c1"

  nft list chain inet filter input | grep -q "$c2" ||     nft add rule inet filter input tcp dport $port accept comment "$c2"

  ABUSE_BACKEND="nft"
}

remove_abuse_nft_existing(){
  nft list chain inet filter input >/dev/null 2>&1 || return 0
  while read -r handle; do
    [[ -n "$handle" ]] && nft delete rule inet filter input handle "$handle" || true
  done < <(nft -a list chain inet filter input 2>/dev/null | awk -v m="$ABUSE_MARKER" '$0 ~ m {print $NF}')
}

apply_abuse_iptables(){
  local port="$1"
  iptables -N MTPROXY_ABUSE 2>/dev/null || true
  iptables -C INPUT -p tcp --dport "$port" -j MTPROXY_ABUSE 2>/dev/null ||     iptables -I INPUT -p tcp --dport "$port" -j MTPROXY_ABUSE

  iptables -C MTPROXY_ABUSE -p tcp --syn -m hashlimit --hashlimit-above "${NEW_CONNS_PER_SEC}/second" --hashlimit-burst "$BURST_NEW_CONNS" --hashlimit-mode srcip --hashlimit-name mtproxy_syn -j DROP 2>/dev/null ||     iptables -A MTPROXY_ABUSE -p tcp --syn -m hashlimit --hashlimit-above "${NEW_CONNS_PER_SEC}/second" --hashlimit-burst "$BURST_NEW_CONNS" --hashlimit-mode srcip --hashlimit-name mtproxy_syn -j DROP

  if [[ "${MAX_CONNS_PER_IP}" =~ ^[0-9]+$ ]] && [[ "${MAX_CONNS_PER_IP}" -gt 0 ]]; then
    iptables -C MTPROXY_ABUSE -p tcp -m connlimit --connlimit-above "$MAX_CONNS_PER_IP" --connlimit-mask 32 -j DROP 2>/dev/null ||       iptables -A MTPROXY_ABUSE -p tcp -m connlimit --connlimit-above "$MAX_CONNS_PER_IP" --connlimit-mask 32 -j DROP
  fi

  iptables -C MTPROXY_ABUSE -j ACCEPT 2>/dev/null || iptables -A MTPROXY_ABUSE -j ACCEPT
  ABUSE_BACKEND="iptables"
}

remove_abuse_iptables_for_port(){
  local port="$1"
  iptables -D INPUT -p tcp --dport "$port" -j MTPROXY_ABUSE 2>/dev/null || true
  iptables -F MTPROXY_ABUSE 2>/dev/null || true
  iptables -X MTPROXY_ABUSE 2>/dev/null || true
}

apply_anti_abuse_if_enabled(){
  local port="$1"
  [[ "$ANTI_ABUSE" == "1" ]] || { ABUSE_BACKEND="none"; return 0; }

  confirm "Anti-abuse will modify firewall rules for TCP/${port}. Continue?"

  log "Anti-abuse is ENABLED (minimal rate limits). Backend preference: ${ABUSE_BACKEND_PREFERRED}"
  case "$ABUSE_BACKEND_PREFERRED" in
    nft)
      have_cmd nft || die "Requested backend nft, but 'nft' not found."
      apply_abuse_nft_existing "$port"
      ;;
    iptables)
      have_cmd iptables || die "Requested backend iptables, but 'iptables' not found."
      apply_abuse_iptables "$port"
      ;;
    auto|*)
      if have_cmd nft && nft_can_use_existing_input; then apply_abuse_nft_existing "$port"
      elif have_cmd iptables; then apply_abuse_iptables "$port"
      else die "Anti-abuse enabled, but no suitable backend found (need nft with inet filter input, or iptables)."
      fi
      ;;
  esac
  log "Anti-abuse backend in use: $ABUSE_BACKEND"
}

status_cmd(){
  need_root
  echo "== MTProxy status =="
  echo
  echo "---- Service ----"
  if service_installed; then
    systemctl status "${SERVICE_NAME}" --no-pager -l || true
  else
    echo "Service: not installed"
  fi

  echo
  echo "---- Listening ports ----"
  if have_cmd ss; then
    ss -lntp 2>/dev/null | grep -E 'mtproto-proxy|:('"${CLIENT_PORT:-8443}"'|'"${STATS_PORT:-8888}"')' || echo "No mtproto-proxy listener found via ss"
  else
    echo "ss not available"
  fi

  echo
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    echo "---- Saved config ($STATE_FILE) ----"
    echo "  MT_REF: ${MT_REF:-<default-branch>}"
    echo "  MT_COMMIT: ${MT_COMMIT:-unknown}"
    echo "  IP: ${SERVER_IP:-}"
    echo "  Client port: ${CLIENT_PORT:-}"
    echo "  Stats port: ${STATS_PORT:-}"
    echo "  Secret: ${LINK_SECRET:-}"
    echo "  Anti-abuse enabled: ${ANTI_ABUSE:-0} (backend: ${ABUSE_BACKEND:-})"
    echo "  Limits: new/s=${NEW_CONNS_PER_SEC:-} burst=${BURST_NEW_CONNS:-} conns/ip=${MAX_CONNS_PER_IP:-}"
    echo "  External IP lookup: $([[ "${NO_EXTERNAL_IP_LOOKUP:-0}" == "1" ]] && echo disabled || echo enabled)"
    echo
    if [[ -n "${SERVER_IP:-}" && -n "${CLIENT_PORT:-}" && -n "${LINK_SECRET:-}" ]]; then
      echo "Telegram links:"
      print_links "$SERVER_IP" "$CLIENT_PORT" "$LINK_SECRET"
    fi
  else
    echo "State file not found: $STATE_FILE"
  fi
}

check_cmd(){
  need_root
  echo "== Version check =="
  echo
  echo "Installer version: $(installer_version || echo "<unknown>")"
  echo "Installer self-update: ${INSTALLER_SELF_UPDATE}"
  if [[ -d "${SCRIPT_DIR}/.git" ]] && have_cmd git; then
    local url
    url="$(git -C "$SCRIPT_DIR" remote get-url "$INSTALLER_REMOTE" 2>/dev/null || true)"
    echo "Installer remote (${INSTALLER_REMOTE}): ${url:-<none>}"
    echo "Trusted remote URL: ${INSTALLER_TRUSTED_REMOTE_URL:-<not set>}"
  fi
  echo
  if [[ -d "${MT_DIR}/.git" ]] && have_cmd git; then
    echo "MTProxy repo: $MT_DIR"
    local cur_commit cur_branch
    cur_commit="$(git -C "$MT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    cur_branch="$(git -C "$MT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    echo "  Current commit: ${cur_commit:-unknown}"
    echo "  Current branch: ${cur_branch:-unknown}"
    if [[ -f "$STATE_FILE" ]]; then
      source "$STATE_FILE"
      echo "  Saved MT_REF: ${MT_REF:-<default-branch>}"
      echo "  Saved MT_COMMIT: ${MT_COMMIT:-unknown}"
    fi
  else
    echo "MTProxy repo not found at $MT_DIR (not installed yet)."
  fi
}

rollback(){
  log "Rollback: removing MTProxy and service..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "$SERVICE_FILE" || true
  systemctl daemon-reload 2>/dev/null || true

  local p=""
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE" || true
    p="${CLIENT_PORT:-}"
  fi
  if [[ -n "$p" ]]; then
    have_cmd nft && remove_abuse_nft_existing || true
    have_cmd iptables && remove_abuse_iptables_for_port "$p" || true
  fi

  rm -rf "$MT_DIR" || true
  rm -f "$STATE_FILE" || true
  id -u "$RUN_USER" >/dev/null 2>&1 && userdel "$RUN_USER" 2>/dev/null || true
  log "Rollback complete."
}

prompt_action_if_installed(){
  [[ -n "$ACTION" ]] && return 0
  if service_installed || [[ -d "$MT_DIR" ]]; then
    echo
    echo "[mtproxy] Existing installation detected."
    echo "[mtproxy] Choose action:"
    echo "  update     - rebuild/update and restart (keep secret/ports)"
    echo "  reinstall  - full reinstall"
    echo "  abort      - exit"
    echo
    local choice=""
    read -r -p "Enter choice [update/reinstall/abort] (default: abort): " choice || true
    choice="${choice:-abort}"
    case "$choice" in
      update|reinstall|abort) ACTION="$choice";;
      *) ACTION="abort";;
    esac
    log "Chosen action: $ACTION"
  fi
}

install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  log "Installing dependencies..."
  apt-get update -y
  apt-get install -y git build-essential libssl-dev zlib1g-dev wget curl xxd ca-certificates
}

prepare_user(){
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    log "Creating system user: $RUN_USER"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  fi
}

clone_and_checkout(){
  [[ -d "$MT_DIR" ]] && rm -rf "$MT_DIR"
  mkdir -p "$MT_DIR"
  chown -R "$RUN_USER":"$RUN_USER" "$MT_DIR" || true

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
}

build_mtproxy(){
  local commit
  commit="$(git -C "$MT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  log "Building MTProxy (commit: ${commit:-unknown})..."
  make -C "$MT_DIR" COMMIT="${commit:-}" || make -C "$MT_DIR"
  echo "$commit"
}

write_systemd(){
  local raw_secret="$1"
  local client_port="$2"
  local stats_port="$3"
  local bin="$MT_DIR/objs/bin/mtproto-proxy"

  [[ -x "$bin" ]] || die "mtproto-proxy not found after build."

  log "Writing systemd unit: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProxy (Telegram MTProto Proxy)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$MT_DIR
ExecStart=$bin -u $RUN_USER -p $stats_port -H $client_port -S $raw_secret --aes-pwd $MT_DIR/proxy-secret $MT_DIR/proxy-multi.conf -M 1
Restart=on-failure
RestartSec=2

LimitNOFILE=1048576
TasksMax=infinity

AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

start_service(){
  systemctl restart "$SERVICE_NAME"
  if ! service_active; then
    log "Service failed to start:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
    exit 1
  fi
}

download_proxy_files(){
  log "Downloading proxy-secret and proxy-multi.conf..."
  # Optional strict verification:
  # - If PROXY_SECRET_SHA256 is set, we verify downloaded proxy-secret via sha256sum.
  #   This is opt-in because upstream does not publish a stable checksum for all releases.
  local secret_url="https://core.telegram.org/getProxySecret"
  local conf_url="https://core.telegram.org/getProxyConfig"
  local secret_dst="$MT_DIR/proxy-secret"
  local conf_dst="$MT_DIR/proxy-multi.conf"

  # Robust download (best-effort retries). Fallback to wget if curl fails.
  if have_cmd curl; then
    curl -fL --retry 3 --retry-delay 1 --max-time 15 "$secret_url" -o "$secret_dst"
    curl -fL --retry 3 --retry-delay 1 --max-time 15 "$conf_url"   -o "$conf_dst"
  elif have_cmd wget; then
    wget -qO "$secret_dst" "$secret_url"
    wget -qO "$conf_dst" "$conf_url"
  else
    die "Neither curl nor wget is available to download proxy files."
  fi

  if [[ -n "${PROXY_SECRET_SHA256:-}" ]]; then
    have_cmd sha256sum || die "PROXY_SECRET_SHA256 is set, but sha256sum is not available."
    echo "${PROXY_SECRET_SHA256}  ${secret_dst}" | sha256sum -c -
    log "proxy-secret sha256 verified."
  fi

  chmod 644 "$secret_dst" "$conf_dst"
}


save_state(){
  local mt_commit="$1" ip="$2" cport="$3" sport="$4" lsecret="$5"
  umask 077
  cat > "$STATE_FILE" <<EOF
# NOTE: This file is readable by root only (0600) and contains the Telegram proxy secret in plaintext.
#       This is intentional: it allows safe update and status reporting.
MT_REF="$MT_REF"
MT_COMMIT="$mt_commit"
SERVER_IP="$ip"
CLIENT_PORT="$cport"
STATS_PORT="$sport"
LINK_SECRET="$lsecret"
MT_DIR="$MT_DIR"
SERVICE_FILE="$SERVICE_FILE"
RUN_USER="$RUN_USER"
ANTI_ABUSE="$ANTI_ABUSE"
ABUSE_BACKEND="$ABUSE_BACKEND"
ABUSE_BACKEND_PREFERRED="$ABUSE_BACKEND_PREFERRED"
NEW_CONNS_PER_SEC="$NEW_CONNS_PER_SEC"
BURST_NEW_CONNS="$BURST_NEW_CONNS"
MAX_CONNS_PER_IP="$MAX_CONNS_PER_IP"
NO_EXTERNAL_IP_LOOKUP="$NO_EXTERNAL_IP_LOOKUP"
EOF
  chmod 600 "$STATE_FILE" || true
}

update_existing(){
  [[ -f "$STATE_FILE" ]] || die "State file not found ($STATE_FILE). Cannot update safely."
  source "$STATE_FILE"

  SERVER_IP="${SERVER_IP:-$(detect_public_ipv4 || true)}"
  [[ -z "$SERVER_IP" ]] && die "Could not detect public IPv4. Use --ip."

  [[ -d "$MT_DIR/.git" ]] || die "MTProxy repo not found at $MT_DIR. Use reinstall."

  log "Updating existing installation in: $MT_DIR"

  if [[ -n "$MT_REF" ]]; then
    log "Updating (pinned) to ref: $MT_REF"
    git_mt fetch --tags --force
    git_mt checkout --force "$MT_REF"
    git_mt submodule update --init --recursive
  else
    log "Updating by pulling default branch (NOT recommended for production)."
    git_mt pull --rebase
    git_mt submodule update --init --recursive
  fi

  local mt_commit
  mt_commit="$(build_mtproxy)"
  start_service

  apply_anti_abuse_if_enabled "$CLIENT_PORT"

  save_state "$mt_commit" "$SERVER_IP" "$CLIENT_PORT" "$STATS_PORT" "$LINK_SECRET"

  log ""
  log "Update completed."
  log "MT_REF: ${MT_REF:-<default-branch>}"
  log "MT_COMMIT: ${mt_commit:-unknown}"
  log "IP: $SERVER_IP"
  log "Port: $CLIENT_PORT"
  log "Secret: $LINK_SECRET"
  echo
  log "Telegram links:"
  print_links "$SERVER_IP" "$CLIENT_PORT" "$LINK_SECRET"
  echo
  print_commands
}

install_fresh(){
  need_root
  install_deps
  prepare_user

  [[ -z "$SERVER_IP" ]] && SERVER_IP="$(detect_public_ipv4 || true)"
  [[ -z "$SERVER_IP" ]] && die "Could not detect public IPv4. Use --ip."

  if [[ -n "$CLIENT_PORT" ]]; then
    [[ "$CLIENT_PORT" == "443" ]] && die "Client port 443 is not allowed."
    [[ "$CLIENT_PORT" =~ ^[0-9]+$ ]] || die "Invalid client port."
    is_tcp_port_free "$CLIENT_PORT" || die "Client port busy."
  else
    CLIENT_PORT="$(pick_free_port CANDIDATE_CLIENT_PORTS)" || die "No free client port."
  fi

  if [[ -n "$STATS_PORT" ]]; then
    [[ "$STATS_PORT" =~ ^[0-9]+$ ]] || die "Invalid stats port."
    is_tcp_port_free "$STATS_PORT" || die "Stats port busy."
  else
    STATS_PORT="$(pick_free_port CANDIDATE_STATS_PORTS)" || die "No free stats port."
  fi

  log "Using IP: $SERVER_IP"
  log "Chosen ports: client(-H)=$CLIENT_PORT, stats(-p)=$STATS_PORT"

  clone_and_checkout
  local mt_commit
  mt_commit="$(build_mtproxy)"
  download_proxy_files

  local raw_secret link_secret
  raw_secret="$(head -c 16 /dev/urandom | xxd -ps -c 32)"
  link_secret="dd${raw_secret}"
  log "Service secret (-S): $raw_secret"
  log "Link secret (dd...): $link_secret"

  write_systemd "$raw_secret" "$CLIENT_PORT" "$STATS_PORT"
  start_service

  apply_anti_abuse_if_enabled "$CLIENT_PORT"

  save_state "$mt_commit" "$SERVER_IP" "$CLIENT_PORT" "$STATS_PORT" "$link_secret"

  log ""
  log "MTProxy installed and running."
  log "MT_REF: ${MT_REF:-<default-branch>}"
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

usage(){
cat <<'EOF'
MTProxy installer

Usage:
  sudo ./install.sh [options]
  sudo ./install.sh status
  sudo ./install.sh check

Self-update (supply-chain safe by default):
  Self-update is ENABLED only if:
    - script is run from a git clone, AND
    - INSTALLER_TRUSTED_REMOTE_URL is set and matches the current remote URL
  Disable: INSTALLER_SELF_UPDATE=0 or --no-self-update

Re-run behavior:
  If an existing installation is detected, choose:
    update | reinstall | abort
  (or pass --action update|reinstall|abort)

Options:
  --ref <TAG|COMMIT>         Pin MTProxy to exact tag/commit (recommended)
  --ip <PUBLIC_IP>
  --no-external-ip           Do not query external IP services (only local routing)
  --client-port <PORT>       (not 443)
  --stats-port <PORT>

  --action update|reinstall|abort
  --no-self-update
  --yes                      Assume "yes" for confirmations (non-interactive safe)

  --anti-abuse               Enable minimal rate limiting (WILL modify firewall rules)
  --abuse-backend auto|nft|iptables
  --new-conns-per-sec <N>
  --burst <N>
  --max-conns-per-ip <N>     (iptables only; 0 disables)

Notes:
  - By default this installer DOES NOT modify firewall rules.
  - If you enable --anti-abuse, it will add rules to EXISTING chains only:
      nft: inet filter input
      iptables: INPUT (via MTPROXY_ABUSE chain)
EOF
}

main(){
  need_root

  case "${1:-}" in
    status) shift; status_cmd; exit 0;;
    check) shift; check_cmd; exit 0;;
    -h|--help) usage; exit 0;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref) MT_REF="${2:-}"; shift 2;;
      --ip) SERVER_IP="${2:-}"; shift 2;;
      --no-external-ip) NO_EXTERNAL_IP_LOOKUP="1"; shift 1;;
      --client-port) CLIENT_PORT="${2:-}"; shift 2;;
      --stats-port) STATS_PORT="${2:-}"; shift 2;;

      --action) ACTION="${2:-}"; shift 2;;
      --no-self-update) INSTALLER_SELF_UPDATE="0"; shift 1;;
      --yes) YES="1"; shift 1;;

      --anti-abuse) ANTI_ABUSE="1"; shift 1;;
      --abuse-backend) ABUSE_BACKEND_PREFERRED="${2:-auto}"; shift 2;;
      --new-conns-per-sec) NEW_CONNS_PER_SEC="${2:-}"; shift 2;;
      --burst) BURST_NEW_CONNS="${2:-}"; shift 2;;
      --max-conns-per-ip) MAX_CONNS_PER_IP="${2:-}"; shift 2;;

      -h|--help) usage; exit 0;;
      *) die "Unknown arg: $1";;
    esac
  done

  self_update_if_possible "$@"

  prompt_action_if_installed
  if [[ -n "$ACTION" ]]; then
    case "$ACTION" in
      abort) die "Aborted by user." ;;
      update) update_existing; exit 0 ;;
      reinstall) ;;
      *) die "Invalid action: $ACTION" ;;
    esac
  fi

  trap rollback ERR

  if [[ "$ACTION" == "reinstall" ]]; then
    log "Reinstall: removing previous installation first..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" || true
    systemctl daemon-reload 2>/dev/null || true

    if [[ -f "$STATE_FILE" ]]; then
      source "$STATE_FILE" || true
      [[ -n "${CLIENT_PORT:-}" ]] && have_cmd nft && remove_abuse_nft_existing || true
      [[ -n "${CLIENT_PORT:-}" ]] && have_cmd iptables && remove_abuse_iptables_for_port "$CLIENT_PORT" || true
    fi

    rm -rf "$MT_DIR" || true
    rm -f "$STATE_FILE" || true
  fi

  install_fresh
  trap - ERR
}

main "$@"
