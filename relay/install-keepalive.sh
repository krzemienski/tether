#!/usr/bin/env bash
# install-keepalive.sh — install the relay sshd keepalive drop-in.
#
# Run as root ON THE RELAY. Idempotent. Validates the config with `sshd -t`
# before reloading, and reverts the drop-in if validation fails so a bad edit
# can never wedge sshd. Uses `reload` (not restart) so live tunnels survive.
#
#   sudo bash relay/install-keepalive.sh
#
# See relay/sshd-tether-keepalive.conf for why this is required.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/sshd-tether-keepalive.conf"
DST="/etc/ssh/sshd_config.d/60-tether-keepalive.conf"

[ "$(uname -s)" = "Linux" ] || { echo "relay drop-in is Linux/sshd only" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing source: $SRC" >&2; exit 1; }

if ! grep -q '^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
  echo "WARNING: /etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf' line." >&2
  echo "The drop-in will not take effect until that include is present." >&2
fi

backup=""
if [ -f "$DST" ]; then
  backup="${DST}.bak.$(date +%s)"
  cp -p "$DST" "$backup"
fi

install -m 0644 -o root -g root "$SRC" "$DST"

if ! sshd -t; then
  echo "sshd -t failed — reverting" >&2
  if [ -n "$backup" ]; then mv -f "$backup" "$DST"; else rm -f "$DST"; fi
  exit 1
fi
[ -n "$backup" ] && rm -f "$backup"

systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "[install-keepalive] installed $DST and reloaded sshd"
echo "[install-keepalive] effective settings:"
sshd -T | grep -iE 'clientalive|tcpkeepalive'
