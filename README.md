# Tether

> Plain `ssh you@your.host` from anywhere — your domain, your relay, no client tooling.

Tether reverse-tunnels a roaming machine's local SSH (or any TCP) to a relay you own. DNS lives on Cloudflare. Any plain OpenSSH client on the public internet can `ssh user@your.host` — no `cloudflared`, no service tokens, no `ProxyCommand`, no Tailscale. Outbound-only on the client side, so it survives any network, NAT, or captive portal.

## Quickstart

### 1. Install the relay (on a public-IP box)

```bash
ssh you@your-relay-vps
curl -fsSL https://raw.githubusercontent.com/krzemienski/tether/main/relay/install-relay.sh | sudo bash
```

Output prints `TETHER_RELAY` (public IP) and `TETHER_SECRET` (hex string). Copy both.

### 2. Install the client (on the roaming machine)

macOS:

```bash
TETHER_RELAY=<from step 1> \
TETHER_SECRET=<from step 1> \
TETHER_REMOTE_PORT=2222 \
TETHER_LOCAL_PORT=22 \
curl -fsSL https://raw.githubusercontent.com/krzemienski/tether/main/client/install-client.sh | sudo bash
```

### 3. Point your DNS

Cloudflare API token with `Zone:DNS:Edit` on your zone:

```bash
CF_API_TOKEN=<token> \
CF_ZONE=your-domain.tld \
CF_HOST=m4.your-domain.tld \
CF_TARGET_IP=<relay public IP> \
bash dns/update-dns.sh
```

(or use legacy global key — see `dns/update-dns.sh` for both auth modes.)

### 4. Connect

```bash
ssh -p 2222 you@m4.your-domain.tld
```

Done. Plain OpenSSH from anywhere on the internet.

## Why Tether and not X?

| Approach | Plain ssh? | Roaming-friendly? | Cost | Verdict |
|---|---|---|---|---|
| **Tether** | yes | yes | $0 (you own relay) | ship it |
| Cloudflare Tunnel + `cloudflared access ssh` | no (needs ProxyCommand) | yes | $0 | requires client tooling |
| Cloudflare Spectrum SSH | yes | **no** (needs public-IP origin) | $25/mo | does not work for roaming clients |
| Direct router port-forward | yes | no (fixed location) | $0 | not portable |
| Tailscale Funnel | no (HTTPS only) | yes | $0 | not for SSH |
| ngrok TCP reserved | yes (custom port) | yes | $8+/mo | hostname:port not your domain |

## Architecture

```
[client] --plain ssh--> [relay public IP:2222] <==reverse tunnel== [roaming m4: bore client] --> localhost:22
                              |
                       Cloudflare DNS:
                       m4.your-domain.tld A --> RELAY_IP (unproxied)
```

Three boxes:

- **Relay** (your VPS) — runs `bore server`, binds public :2222, control on :7835.
- **Client** (your laptop) — runs `bore local 22 --to RELAY --port 2222 --secret X`. launchd KeepAlive.
- **Cloudflare DNS** — one A record, unproxied (proxy breaks raw TCP).

## Components

| Path | Purpose |
|---|---|
| `bin/tether` | top-level CLI: `install relay`, `install client`, `dns`, `status`, `destroy` |
| `relay/install-relay.sh` | one-shot Ubuntu/Debian relay installer |
| `relay/tether-relay.service` | systemd unit |
| `client/install-client.sh` | one-shot macOS client installer |
| `client/com.tether.client.plist` | launchd plist template |
| `dns/update-dns.sh` | Cloudflare DNS upsert (idempotent) |
| `dns/tether-dns.cron` | crontab line for DDNS on the relay |
| `examples/config.env.example` | configuration template |

## Security posture

Tether deliberately puts your sshd on the public internet via the relay. Password auth is brute-forceable. This is honest exposure, not hidden risk.

Recommended hardening (not enforced by Tether):

- `fail2ban` on the laptop
- non-22 internal port (still works through bore)
- key-only auth once you have keys deployed
- restrict `AllowUsers` in `sshd_config`

Tether never modifies `sshd_config` automatically.

## Underlying tunnel

[bore](https://github.com/ekzhang/bore) — MIT, single static binary. Tether is a thin opinionated wrapper around it (systemd unit, launchd plist, DDNS, lifecycle commands).

## License

MIT. See [LICENSE](./LICENSE).
