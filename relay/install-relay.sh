#!/usr/bin/env bash
# tether/relay/install-relay.sh
# One-shot installer for the Tether relay on Ubuntu/Debian (systemd).
# Run as root on a public-IP VPS.
#
# Output: prints TETHER_RELAY (public IP) and TETHER_SECRET (hex) for client config.

set -Eeuo pipefail
umask 077

BORE_VERSION="${BORE_VERSION:-0.5.1}"
INSTALL_PREFIX="/usr/local/bin"
ETC_DIR="/etc/tether"
SECRET_FILE="${ETC_DIR}/secret"
SYSTEMD_UNIT="/etc/systemd/system/tether-relay.service"
SERVICE_USER="tether"
TUNNEL_PORT="${TETHER_REMOTE_PORT:-2222}"
CONTROL_PORT="${TETHER_CONTROL_PORT:-7835}"
LOG_TAG="tether-relay"

log()  { printf '[%s] [INFO]  %s\n' "$LOG_TAG" "$*" >&2; }
warn() { printf '[%s] [WARN]  %s\n' "$LOG_TAG" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$LOG_TAG" "$*" >&2; }
die()  { err "$*"; exit 1; }
trap 'err "Failed at line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || die "Must run as root (use sudo)"

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

install_deps() {
  log "Installing dependencies"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl ufw ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl jq openssl firewalld ca-certificates
  else
    warn "Unknown package manager; assuming curl/jq/openssl already present"
  fi
  require_cmd curl
  require_cmd jq
  require_cmd openssl
}

install_bore() {
  local arch tarball url tmp
  arch="$(detect_arch)"
  tarball="bore-v${BORE_VERSION}-${arch}-unknown-linux-musl.tar.gz"
  url="https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/${tarball}"
  tmp="$(mktemp -d)"
  log "Downloading bore v${BORE_VERSION} (${arch})"
  curl -fsSL -o "${tmp}/bore.tar.gz" "$url" || die "bore download failed: $url"
  tar -xzf "${tmp}/bore.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/bore" "${INSTALL_PREFIX}/bore"
  rm -rf "$tmp"
  "${INSTALL_PREFIX}/bore" --version >/dev/null || die "bore binary not executable"
  log "bore installed at ${INSTALL_PREFIX}/bore"
}

create_user() {
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "Creating service user: $SERVICE_USER"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  else
    log "Service user already exists: $SERVICE_USER"
  fi
}

generate_secret() {
  install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$ETC_DIR"
  if [ -s "$SECRET_FILE" ]; then
    log "Secret already exists at $SECRET_FILE (preserving)"
  else
    log "Generating shared secret"
    openssl rand -hex 32 > "$SECRET_FILE"
    chown "$SERVICE_USER":"$SERVICE_USER" "$SECRET_FILE"
    chmod 0600 "$SECRET_FILE"
  fi
}

write_unit() {
  log "Writing systemd unit: $SYSTEMD_UNIT"
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Tether relay (bore server)
Documentation=https://github.com/krzemienski/tether
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
EnvironmentFile=-${ETC_DIR}/env
ExecStart=/bin/sh -c '${INSTALL_PREFIX}/bore server --secret "\$(cat ${SECRET_FILE})" --min-port ${TUNNEL_PORT} --max-port ${TUNNEL_PORT}'
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=true
ReadOnlyPaths=${ETC_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "Opening ufw ports ${CONTROL_PORT}/tcp and ${TUNNEL_PORT}/tcp"
    ufw allow "${CONTROL_PORT}/tcp" >/dev/null
    ufw allow "${TUNNEL_PORT}/tcp" >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "Opening firewalld ports ${CONTROL_PORT}/tcp and ${TUNNEL_PORT}/tcp"
    firewall-cmd --permanent --add-port="${CONTROL_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  else
    warn "No active ufw/firewalld detected; ensure ${CONTROL_PORT}/tcp and ${TUNNEL_PORT}/tcp are reachable"
  fi
}

start_service() {
  log "Reloading systemd and enabling service"
  systemctl daemon-reload
  systemctl enable tether-relay.service >/dev/null
  systemctl restart tether-relay.service
  sleep 2
  if systemctl is-active --quiet tether-relay.service; then
    log "tether-relay is active"
  else
    journalctl -u tether-relay.service --no-pager -n 20 || true
    die "tether-relay failed to start"
  fi
}

validate_listening() {
  local ok=0
  for _ in 1 2 3 4 5; do
    if ss -lntH 2>/dev/null | awk '{print $4}' | grep -q ":${CONTROL_PORT}\$"; then
      ok=1; break
    fi
    sleep 1
  done
  [ "$ok" -eq 1 ] || die "Control port ${CONTROL_PORT} not listening"
  log "Control port ${CONTROL_PORT} is listening"
}

discover_public_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsS --max-time 5 "$u" 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$ip" ] && break
  done
  [ -n "$ip" ] || die "Could not detect public IP"
  printf '%s' "$ip"
}

main() {
  install_deps
  install_bore
  create_user
  generate_secret
  write_unit
  open_firewall
  start_service
  validate_listening

  local secret pub_ip
  secret="$(cat "$SECRET_FILE")"
  pub_ip="$(discover_public_ip)"

  cat <<EOF

================================================================
  Tether relay installed
================================================================

  TETHER_RELAY=${pub_ip}
  TETHER_SECRET=${secret}
  TETHER_REMOTE_PORT=${TUNNEL_PORT}
  TETHER_CONTROL_PORT=${CONTROL_PORT}

  Next: on the roaming client, run:

  TETHER_RELAY=${pub_ip} \\
  TETHER_SECRET=${secret} \\
  TETHER_REMOTE_PORT=${TUNNEL_PORT} \\
  TETHER_LOCAL_PORT=22 \\
  curl -fsSL https://raw.githubusercontent.com/krzemienski/tether/main/client/install-client.sh | sudo bash

  Then point DNS:

  m4.<your-zone> A ${pub_ip}    (unproxied)

  Verify from anywhere:
  ssh -p ${TUNNEL_PORT} <user>@<your-host>
================================================================
EOF
}

main "$@"
