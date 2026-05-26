#!/usr/bin/env bash
# install-heal.sh — install com.tether.heal launchd watchdog on macOS.
#
# Renders bin/com.tether.heal.plist with the absolute repo path,
# installs to /Library/LaunchDaemons, bootstraps it, and verifies one tick.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

LABEL="com.tether.heal"
SRC_PLIST="${HERE}/${LABEL}.plist"
DST_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HEAL_SCRIPT="${HERE}/tether-heal.sh"

[ "$(uname)" = "Darwin" ] || { echo "macOS only" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
[ -f "$SRC_PLIST" ] || { echo "missing: $SRC_PLIST" >&2; exit 1; }
[ -f "$HEAL_SCRIPT" ] || { echo "missing: $HEAL_SCRIPT" >&2; exit 1; }

chmod 0755 "$HEAL_SCRIPT"
touch /var/log/tether-heal.log /var/log/tether-heal.out.log /var/log/tether-heal.err.log
chmod 0644 /var/log/tether-heal.log /var/log/tether-heal.out.log /var/log/tether-heal.err.log

# Render plist with absolute repo path
sed "s|{{TETHER_ROOT}}|${ROOT}|g" "$SRC_PLIST" > "$DST_PLIST"
chown root:wheel "$DST_PLIST"
chmod 0644 "$DST_PLIST"

# Reload (idempotent)
launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$DST_PLIST"

echo "[install-heal] installed and bootstrapped ${LABEL}"
echo "[install-heal] running one tick now to verify..."
sleep 2
launchctl kickstart -k "system/${LABEL}" || true
sleep 4

echo "[install-heal] last 10 log lines:"
tail -n 10 /var/log/tether-heal.log 2>/dev/null || echo "(no log yet)"
