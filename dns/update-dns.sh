#!/usr/bin/env bash
# tether/dns/update-dns.sh
# Idempotent Cloudflare DNS A record upsert.
#
# Required env (one of two auth modes):
#   Mode A — scoped API token (preferred):
#     CF_API_TOKEN  (Zone:DNS:Edit on the zone)
#   Mode B — legacy global API key:
#     CF_API_EMAIL
#     CF_API_KEY
#
# Required env (always):
#   CF_ZONE        (zone name, e.g. example.com)
#   CF_HOST        (full hostname, e.g. m4.example.com)
#   CF_TARGET_IP   (IP to point at)  — or omit to auto-detect this host's public IP
#
# Optional:
#   CF_TTL         (default 60)
#   CF_PROXIED     (default false — must be false for raw TCP/SSH)

set -Eeuo pipefail

CF_API="https://api.cloudflare.com/client/v4"
CF_TTL="${CF_TTL:-60}"
CF_PROXIED="${CF_PROXIED:-false}"
LOG_TAG="tether-dns"

log()  { printf '[%s] [INFO]  %s\n' "$LOG_TAG" "$*" >&2; }
warn() { printf '[%s] [WARN]  %s\n' "$LOG_TAG" "$*" >&2; }
die()  { printf '[%s] [ERROR] %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl required"
command -v jq   >/dev/null 2>&1 || die "jq required"

[ -n "${CF_ZONE:-}" ] || die "CF_ZONE required"
[ -n "${CF_HOST:-}" ] || die "CF_HOST required"

if [ -z "${CF_TARGET_IP:-}" ]; then
  log "Auto-detecting public IP"
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    CF_TARGET_IP="$(curl -fsS --max-time 5 "$u" 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$CF_TARGET_IP" ] && break
  done
  [ -n "$CF_TARGET_IP" ] || die "Could not detect public IP"
  log "Detected: $CF_TARGET_IP"
fi

cf_headers() {
  if [ -n "${CF_API_TOKEN:-}" ]; then
    printf 'Authorization: Bearer %s\nContent-Type: application/json' "$CF_API_TOKEN"
  elif [ -n "${CF_API_EMAIL:-}" ] && [ -n "${CF_API_KEY:-}" ]; then
    printf 'X-Auth-Email: %s\nX-Auth-Key: %s\nContent-Type: application/json' "$CF_API_EMAIL" "$CF_API_KEY"
  else
    die "Either CF_API_TOKEN or CF_API_EMAIL+CF_API_KEY required"
  fi
}

cf_api() {
  local method="$1" path="$2" data="${3:-}"
  local headers
  headers="$(cf_headers)"
  local args=( --fail-with-body -sS -X "$method" "${CF_API}${path}" )
  while IFS= read -r h; do args+=( -H "$h" ); done <<< "$headers"
  if [ -n "$data" ]; then args+=( --data "$data" ); fi
  curl "${args[@]}"
}

zone_id() {
  local resp zid
  resp="$(cf_api GET "/zones?name=${CF_ZONE}")" || die "Zone lookup failed"
  zid="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
  [ -n "$zid" ] || die "Zone not found: ${CF_ZONE}"
  printf '%s' "$zid"
}

upsert_a() {
  local zid="$1"
  local resp rec_id rec_content rec_proxied body
  body="$(jq -nc --arg n "$CF_HOST" --arg c "$CF_TARGET_IP" --argjson t "$CF_TTL" --argjson p "$CF_PROXIED" \
    '{type:"A",name:$n,content:$c,ttl:$t,proxied:$p}')"
  resp="$(cf_api GET "/zones/${zid}/dns_records?name=${CF_HOST}")" || die "DNS list failed"

  # If existing CNAME present, delete it first (cannot coexist with A)
  printf '%s' "$resp" | jq -r '.result[]? | select(.type=="CNAME") | .id' | while read -r cid; do
    [ -n "$cid" ] || continue
    log "Removing conflicting CNAME ${cid}"
    cf_api DELETE "/zones/${zid}/dns_records/${cid}" >/dev/null
  done

  resp="$(cf_api GET "/zones/${zid}/dns_records?type=A&name=${CF_HOST}")" || die "DNS list failed"
  rec_id="$(printf '%s' "$resp"      | jq -r '.result[0].id      // empty')"
  rec_content="$(printf '%s' "$resp" | jq -r '.result[0].content // empty')"
  rec_proxied="$(printf '%s' "$resp" | jq -r '.result[0].proxied // false')"

  if [ -z "$rec_id" ]; then
    log "Creating A ${CF_HOST} -> ${CF_TARGET_IP} (proxied=${CF_PROXIED}, ttl=${CF_TTL})"
    cf_api POST "/zones/${zid}/dns_records" "$body" >/dev/null
  elif [ "$rec_content" != "$CF_TARGET_IP" ] || [ "$rec_proxied" != "$CF_PROXIED" ]; then
    log "Updating A ${CF_HOST}: ${rec_content}(proxied=${rec_proxied}) -> ${CF_TARGET_IP}(proxied=${CF_PROXIED})"
    cf_api PUT "/zones/${zid}/dns_records/${rec_id}" "$body" >/dev/null
  else
    log "A ${CF_HOST} already correct"
  fi
}

main() {
  local zid
  zid="$(zone_id)"
  upsert_a "$zid"
  log "Done. dig +short ${CF_HOST} should return ${CF_TARGET_IP} within ${CF_TTL}s"
}

main "$@"
