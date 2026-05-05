# Tether — Architecture

## Goal

Plain `ssh user@your.host` from any client on the public internet, where `your.host` is a roaming machine (laptop) that may have no public IP, may live behind NAT or captive portals, and may roam across many networks per day.

## Constraints

- Client side: zero tooling. Stock OpenSSH only.
- Roaming side: outbound-only. No inbound ports, no router admin.
- DNS: own zone (Cloudflare in this implementation, but provider-agnostic in design).
- License: MIT. Self-hostable. No vendor SaaS.

## Why not Cloudflare alone

Cloudflare's edge serves HTTP/HTTPS at public ports for free. Raw TCP/22 at the edge requires Cloudflare Spectrum, which:

1. Needs a Pro plan or higher ($25/mo).
2. Cannot use a Cloudflare Tunnel as origin for TCP applications (per official docs at `developers.cloudflare.com/spectrum/reference/limitations/`).

Therefore Spectrum SSH requires a public-IP origin — which is exactly what a roaming laptop does not have. Cloudflare cannot be used as the relay for this use case at any price.

Cloudflare's role in Tether is reduced to free DNS hosting (one A record). Any DNS provider works.

## Components

```
[client] --plain ssh--> [relay public IP:2222] <==reverse tunnel== [roaming m4: bore client] --> localhost:22
```

| Component | Lives on | Software |
|---|---|---|
| Relay daemon | VPS with public IP | bore server (systemd) |
| Tunnel client | Roaming laptop | bore client (launchd or systemd) |
| DNS automator | Relay (cron) | curl + jq + Cloudflare API |
| Local SSH | Laptop | stock OpenSSH on :22 |
| Installer | Operator workstation | bash CLI |

## Connection sequence

1. User runs `ssh -p 2222 user@m4.example.com`.
2. Resolver returns relay public IP (Cloudflare A record, 60s TTL).
3. Client connects TCP `relay_ip:2222`.
4. Relay's bore server forwards the new TCP stream over the persistent control channel to the laptop's bore client.
5. Laptop bore client opens `127.0.0.1:22` to local sshd.
6. SSH handshake, password auth, shell — all transparent end-to-end.

## Resilience

- **Network change on laptop:** bore client auto-reconnects on TCP drop. launchd `KeepAlive=true` restarts the process on crash. Tunnel typically re-establishes within seconds of the laptop reaching the new network.
- **Relay reboot:** systemd restarts bore server. Laptop reconnects automatically.
- **Relay public IP change** (residential ISPs, DDNS scenarios): cron on relay calls Cloudflare API every 5 min, idempotent upsert. Stale DNS is bounded by 60s TTL.

## Security posture

The roaming laptop's sshd is reachable from the public internet via the relay. Brute-force resistance is the responsibility of:

- Strong passwords (operator)
- Optional: `fail2ban` on the laptop
- Optional: `AllowUsers` restriction in `sshd_config`
- Optional: switch to key-only auth once keys are deployed

Tether ships with this exposure documented; it does not silently weaken or harden sshd.

The bore control channel itself is authenticated via a 32-byte hex shared secret. Without the secret, no client can claim the relay's bound port.

## Failure modes

| Failure | User-visible symptom | Behavior |
|---|---|---|
| Relay down | `ssh: connect: connection refused` | DNS still resolves; clean error. |
| Laptop offline | TCP connect succeeds, then silent drop | bore relay accepts then closes. |
| DNS stale during IP change | Connection to old IP times out | Resolves within 60s TTL window. |
| Shared secret mismatch | bore client logs "auth failed" | Operator rotates secret on both sides. |

## Multi-host (v1.1)

Each laptop binds a different remote port on the relay. DNS:

- `m4.example.com` A → `relay_ip` (port 2222 in client config)
- `work.example.com` A → `relay_ip` (port 2223 in client config)

Or multiple relays — one per laptop.

## Tunnel backend

Tether uses [bore](https://github.com/ekzhang/bore) (MIT, Rust) by default. The CLI shell-outs are intentionally thin so swapping to `frp`, `rathole`, `chisel`, or `sish` is a contained change.

## What Tether is not

- Not a VPN. No virtual network interfaces.
- Not a SaaS. No accounts, no telemetry, no central control plane.
- Not a security product. It is exposure plumbing — security is your sshd's responsibility.
- Not zero-trust. Add Cloudflare Access, Tailscale SSH, or Teleport on top if you want identity-aware proxying.
