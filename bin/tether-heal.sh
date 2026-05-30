#!/usr/bin/env bash
# tether-heal — watchdog for the m4 client side of a Tether reverse tunnel.
#
# Architecture: com.tether.client runs `ssh -N -R 127.0.0.1:2222:localhost:22
# nick@home.hack.ski`. The relay exposes the tunnel as 127.0.0.1:2222 on its
# own loopback; external users reach m4 via the relay as a jump host:
#   ssh -J nick@home.hack.ski -p 2222 nick@localhost
# Only the relay's port 22 needs to be public (the home router already
# forwards it) — ports 2222/7835 do NOT need router forwarding.
#
# Runs on the *client* host (m4). On every invocation it:
#   1. Verifies the com.tether.client launchd job is loaded (transient launchd
#      states are tolerated — only genuine failures trigger a kick)
#   2. Verifies the reverse tunnel is bound on the relay (ssh to relay, check
#      127.0.0.1:2222 is listening) — the only probe that proves end-to-end
#      health, since the tunnel port is not reachable over the WAN directly
#   3. Re-syncs Cloudflare DNS for the public hostname (covers relay IP drift)
#
# Designed to be invoked by a launchd watchdog every 60s — see install-heal.sh.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# ---------- config ----------
ENV_FILE="${TETHER_ENV_FILE:-${ROOT}/.env}"
LOG_FILE="${TETHER_HEAL_LOG:-/var/log/tether-heal.log}"
LAUNCHD_LABEL="com.tether.client"
LAUNCHD_PLIST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
PROBE_TIMEOUT="${TETHER_PROBE_TIMEOUT:-5}"

# Defaults — overridden by env file
RELAY_HOST="${TETHER_RELAY:-home.hack.ski}"
REMOTE_PORT="${TETHER_REMOTE_PORT:-2222}"
CF_HOST="${CF_HOST:-${CF_DOMAIN:-m4.hack.ski}}"
CF_ZONE="${CF_ZONE:-hack.ski}"

# SSH identity used by the reverse tunnel + the relay-side health probe.
# heal runs as root, but the tunnel runs as this user with this key.
TUNNEL_USER="${TETHER_TUNNEL_USER:-nick}"
TUNNEL_KEY="${TETHER_TUNNEL_KEY:-/Users/nick/.ssh/id_rsa}"
TUNNEL_KNOWN_HOSTS="${TETHER_KNOWN_HOSTS:-/Users/nick/.ssh/known_hosts}"

# Run an ssh command on the relay as the tunnel user (key auth, no prompts).
relay_ssh() {
  sudo -u "$TUNNEL_USER" /usr/bin/ssh \
    -i "$TUNNEL_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout="$PROBE_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$TUNNEL_KNOWN_HOSTS" \
    "${TUNNEL_USER}@${RELAY_HOST}" "$@"
}

# ---------- logging ----------
log() {
  local msg="[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
  printf '%s\n' "$msg" | tee -a "$LOG_FILE" >&2
}

die() { log "FATAL: $*"; exit 1; }

# ---------- env loader ----------
load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
  fi
  # Map legacy names to canonical
  : "${CF_API_TOKEN:=${CF_TOKEN:-}}"
  : "${CF_HOST:=${CF_DOMAIN:-m4.hack.ski}}"
  export CF_API_TOKEN CF_HOST CF_ZONE
}

# ---------- root guard ----------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (launchd starts this as root; for manual runs use: sudo $0)"
  fi
}

# ---------- check 1: launchd job ----------
# launchctl state machine (per Apple docs):
#   running                         OK
#   waiting / running on demand     OK (KeepAlive idle)
#   xpcproxy / spawn scheduled /
#     starting                      TRANSIENT — do NOT kick (formerly caused
#                                   self-inflicted flap loops during startup)
#   exited / not running            FAILED — kickstart
#   <unloaded>                      MISSING — bootstrap
check_launchd() {
  local raw state pid
  raw="$(launchctl print "system/${LAUNCHD_LABEL}" 2>/dev/null)"
  if [ -z "$raw" ]; then
    log "launchd: job not loaded — bootstrapping"
    launchctl bootstrap system "$LAUNCHD_PLIST" 2>>"$LOG_FILE" || die "bootstrap failed"
    sleep 2
    return 0
  fi
  state="$(printf '%s\n' "$raw" | awk -F'= ' '/^\tstate = /{print $2; exit}')"
  pid="$(printf '%s\n' "$raw" | awk -F'= ' '/^\tpid = /{print $2; exit}')"

  case "$state" in
    running)
      if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
        log "launchd: OK (pid=${pid})"
      else
        log "launchd: state=running but pid ${pid:-none} dead — kicking"
        launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>>"$LOG_FILE" || true
        sleep 2
      fi ;;
    waiting|"running on demand")
      log "launchd: idle (state=${state}) — KeepAlive on demand"
      ;;
    xpcproxy|"spawn scheduled"|starting)
      log "launchd: transient state=${state} — waiting (no kick)"
      ;;
    exited|"not running")
      log "launchd: state=${state} — kicking job"
      launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>>"$LOG_FILE" || \
        log "kickstart failed (will retry next tick)"
      sleep 2 ;;
    *)
      log "launchd: unrecognized state=${state} pid=${pid:-none} — leaving alone"
      ;;
  esac
}

# ---------- check 2: tunnel reachability ----------
# Two-phase probe to defeat the stale-tunnel failure mode:
#   (a) bind check    — is :${REMOTE_PORT} in LISTEN on the relay?
#   (b) E2E check     — does ssh through that port actually reach m4?
# A stale sshd-session can keep the port bound while the data channel is dead;
# in that state the client's new connection gets "remote port forwarding
# failed for listen port" and respawn-flaps forever. (b) catches it.
check_tunnel() {
  if ! relay_ssh true 2>/dev/null; then
    log "tunnel: relay ${RELAY_HOST} unreachable over ssh — network/relay down, NOT kicking client"
    return 0
  fi

  # (a) bind check
  if ! relay_ssh "ss -tln | awk '{print \$4}' | grep -qE ':${REMOTE_PORT}\$'" 2>/dev/null; then
    log "tunnel: relay up but :${REMOTE_PORT} not bound — kicking client"
    launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>>"$LOG_FILE" || true
    sleep 6
    relay_ssh "ss -tln | awk '{print \$4}' | grep -qE ':${REMOTE_PORT}\$'" 2>/dev/null \
      && log "tunnel: bind recovered after kickstart" \
      || log "tunnel: bind STILL DOWN after kickstart"
    return 0
  fi

  # (b) E2E probe: ssh through the tunnel from the relay's loopback to m4.
  # Uses BatchMode (no prompts) + short timeout. We do NOT trust ssh's known_hosts
  # on the relay for 127.0.0.1:2222 since multiple respawns rotate host keys.
  local probe_out
  probe_out="$(relay_ssh "ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=${PROBE_TIMEOUT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${REMOTE_PORT} ${TUNNEL_USER}@127.0.0.1 'echo TUNNEL_E2E_OK' 2>&1" 2>/dev/null)"
  if printf '%s' "$probe_out" | grep -q TUNNEL_E2E_OK; then
    log "tunnel: healthy (bind + E2E ok)"
    return 0
  fi

  log "tunnel: STALE — port bound but E2E failed (${probe_out//$'\n'/ | }) — killing stale sshd-session + kicking client"
  # Kill any nick-owned sshd-session children on the relay. Cannot touch the
  # root-owned [priv] half over ssh, but killing the child closes the channel
  # and root reaps the priv side automatically.
  relay_ssh "pkill -u ${TUNNEL_USER} -f 'sshd-session: ${TUNNEL_USER}\$' 2>/dev/null; pkill -u ${TUNNEL_USER} -f 'sshd-session: ${TUNNEL_USER}@notty' 2>/dev/null; true" 2>/dev/null || true
  sleep 2
  launchctl kickstart -k "system/${LAUNCHD_LABEL}" 2>>"$LOG_FILE" || true
  sleep 6
  probe_out="$(relay_ssh "ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=${PROBE_TIMEOUT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${REMOTE_PORT} ${TUNNEL_USER}@127.0.0.1 'echo TUNNEL_E2E_OK' 2>&1" 2>/dev/null)"
  if printf '%s' "$probe_out" | grep -q TUNNEL_E2E_OK; then
    log "tunnel: E2E recovered after stale-kill + kickstart"
  else
    log "tunnel: E2E STILL DOWN after stale-kill + kickstart (${probe_out//$'\n'/ | })"
  fi
}

# ---------- check 2b: UPnP port-forward (router) ----------
# Many residential routers expose port-forwards as UPnP leases that expire on
# router reboot or after a TTL. Without a static rule the WAN side of the
# tunnel silently disappears. We re-assert a permanent (lease=0) mapping every
# tick — UPnP is idempotent, so this is cheap and self-healing.
# Set TETHER_UPNP=0 in .env to disable (e.g., if the router has a static rule).
check_upnp() {
  local relay_lan="${TETHER_RELAY_LAN_IP:-192.168.0.36}"
  local desc="${TETHER_UPNP_DESC:-tether-ssh}"
  if [ "${TETHER_UPNP:-1}" != "1" ]; then
    return 0
  fi
  if ! relay_ssh "command -v upnpc >/dev/null" 2>/dev/null; then
    log "upnp: upnpc missing on relay — skipping (install miniupnpc to enable)"
    return 0
  fi
  local out
  out="$(relay_ssh "upnpc -e '${desc}' -a ${relay_lan} ${REMOTE_PORT} ${REMOTE_PORT} TCP 0 2>&1 | grep -E 'redirected|failed|error|conflict' | head -1" 2>/dev/null)"
  if [ -z "$out" ]; then
    log "upnp: no IGD response (router may not support UPnP or it's disabled)"
  else
    log "upnp: ${out}"
  fi
}

# ---------- check 3: DNS ----------
check_dns() {
  local relay_ip
  relay_ip="$(dig +short "$RELAY_HOST" @1.1.1.1 2>/dev/null | tail -1)"
  if [ -z "$relay_ip" ]; then
    log "dns: cannot resolve relay ${RELAY_HOST} — skipping DNS sync"
    return 0
  fi

  local current_ip
  current_ip="$(dig +short "$CF_HOST" @1.1.1.1 2>/dev/null | tail -1)"
  if [ "$current_ip" = "$relay_ip" ]; then
    log "dns: ${CF_HOST} -> ${current_ip} (correct)"
    return 0
  fi

  log "dns: ${CF_HOST} -> ${current_ip:-none}, expected ${relay_ip} — upserting"
  if [ -z "${CF_API_TOKEN:-}" ]; then
    log "dns: CF_API_TOKEN missing — cannot upsert"
    return 0
  fi
  CF_TARGET_IP="$relay_ip" CF_API_TOKEN="$CF_API_TOKEN" \
    CF_HOST="$CF_HOST" CF_ZONE="$CF_ZONE" \
    bash "${ROOT}/dns/update-dns.sh" >>"$LOG_FILE" 2>&1 || \
    log "dns: upsert failed"
}

# ---------- main ----------
main() {
  require_root
  load_env

  log "==== tether-heal tick start ===="
  check_launchd
  check_tunnel
  check_upnp
  check_dns
  log "==== tether-heal tick end ===="
}

main "$@"
