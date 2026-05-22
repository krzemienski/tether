#!/usr/bin/env bash
# tether/client/install-client.sh
# One-shot installer for the Tether client on macOS (launchd) or Linux (systemd).
# Run as root.
#
# Required env:
#   TETHER_RELAY        (relay public IP or hostname)
#   TETHER_SECRET       (hex string from relay install)
#   TETHER_REMOTE_PORT  (port the relay binds; default 2222)
#   TETHER_LOCAL_PORT   (local sshd port; default 22)

set -Eeuo pipefail
umask 077

BORE_VERSION="${BORE_VERSION:-0.6.0}"
INSTALL_PREFIX="/usr/local/bin"
ETC_DIR="/etc/tether"
SECRET_FILE="${ETC_DIR}/secret"
LAUNCHD_PLIST="/Library/LaunchDaemons/com.tether.client.plist"
LAUNCHD_LABEL="com.tether.client"
SYSTEMD_UNIT="/etc/systemd/system/tether-client.service"
LOG_TAG="tether-client"

REMOTE_PORT="${TETHER_REMOTE_PORT:-2222}"
LOCAL_PORT="${TETHER_LOCAL_PORT:-22}"

log()  { printf '[%s] [INFO]  %s\n' "$LOG_TAG" "$*" >&2; }
warn() { printf '[%s] [WARN]  %s\n' "$LOG_TAG" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$LOG_TAG" "$*" >&2; }
die()  { err "$*"; exit 1; }
trap 'err "Failed at line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || die "Must run as root (use sudo)"
[ -n "${TETHER_RELAY:-}" ]  || die "TETHER_RELAY env var required"
[ -n "${TETHER_SECRET:-}" ] || die "TETHER_SECRET env var required"

detect_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

bore_release_file() {
  local arch os
  arch="$(detect_arch)"
  os="$(detect_os)"
  case "$os" in
    macos) printf 'bore-v%s-%s-apple-darwin.tar.gz' "$BORE_VERSION" "$arch" ;;
    linux) printf 'bore-v%s-%s-unknown-linux-musl.tar.gz' "$BORE_VERSION" "$arch" ;;
  esac
}

install_bore() {
  local file url tmp
  file="$(bore_release_file)"
  url="https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/${file}"
  tmp="$(mktemp -d)"
  log "Downloading bore v${BORE_VERSION}"
  curl -fsSL -o "${tmp}/bore.tar.gz" "$url" || die "bore download failed: $url"
  tar -xzf "${tmp}/bore.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/bore" "${INSTALL_PREFIX}/bore"
  rm -rf "$tmp"
  "${INSTALL_PREFIX}/bore" --version >/dev/null || die "bore binary not executable"
  log "bore installed at ${INSTALL_PREFIX}/bore"
}

write_secret() {
  install -d -m 0700 "$ETC_DIR"
  printf '%s' "$TETHER_SECRET" > "$SECRET_FILE"
  chmod 0600 "$SECRET_FILE"
  log "Secret written to $SECRET_FILE"
}

write_launchd() {
  log "Writing launchd plist: $LAUNCHD_PLIST"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>exec ${INSTALL_PREFIX}/bore local ${LOCAL_PORT} --to ${TETHER_RELAY} --port ${REMOTE_PORT} --secret "\$(cat ${SECRET_FILE})"</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>/var/log/tether-client.out.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/tether-client.err.log</string>
</dict>
</plist>
EOF
  chown root:wheel "$LAUNCHD_PLIST"
  chmod 0644 "$LAUNCHD_PLIST"
}

bootstrap_launchd() {
  log "Bootstrapping launchd"
  launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  launchctl bootstrap system "$LAUNCHD_PLIST"
  launchctl enable "system/${LAUNCHD_LABEL}"
  sleep 2
}

write_systemd() {
  log "Writing systemd unit: $SYSTEMD_UNIT"
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Tether client (bore local)
Documentation=https://github.com/krzemienski/tether
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'exec ${INSTALL_PREFIX}/bore local ${LOCAL_PORT} --to ${TETHER_RELAY} --port ${REMOTE_PORT} --secret "\$(cat ${SECRET_FILE})"'
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
User=root
Group=root
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=${ETC_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
  systemctl daemon-reload
  systemctl enable --now tether-client.service
}

validate_running() {
  local ok=0
  for i in 1 2 3 4 5 6 7 8; do
    if pgrep -f "bore local ${LOCAL_PORT} --to ${TETHER_RELAY}" >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 1
  done
  if [ "$ok" -eq 1 ]; then
    log "tether client process is running"
  else
    case "$(detect_os)" in
      macos) tail -n 30 /var/log/tether-client.err.log 2>/dev/null || true ;;
      linux) journalctl -u tether-client --no-pager -n 30 || true ;;
    esac
    die "tether client not running"
  fi
}

main() {
  install_bore
  write_secret
  case "$(detect_os)" in
    macos)
      write_launchd
      bootstrap_launchd
      ;;
    linux)
      write_systemd
      ;;
  esac
  validate_running

  cat <<EOF

================================================================
  Tether client installed
================================================================

  Tunnel: 0.0.0.0:${REMOTE_PORT} on ${TETHER_RELAY}
       -> localhost:${LOCAL_PORT} on this machine

  Verify from anywhere on the internet:
    ssh -p ${REMOTE_PORT} <user>@<your-host>

  Logs:
EOF
  case "$(detect_os)" in
    macos)
      echo "    tail -f /var/log/tether-client.{out,err}.log"
      ;;
    linux)
      echo "    journalctl -u tether-client -f"
      ;;
  esac
  echo "================================================================"
}

main "$@"
