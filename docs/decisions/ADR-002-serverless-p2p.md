# ADR-002: Serverless peer-to-peer — no hub, no relay, no accounts

## Status
Accepted (supersedes the initial "Thelxis Hub" design, abandoned the same day before any release)

## Date
2026-10-11

## Context
The product owner's core requirement: connections go directly PC ↔ PC, encrypted end-to-end, decrypted and decoded
only on the two devices; no third-party services and no own server in the path. Without any rendezvous, two peers
both behind carrier-grade NAT cannot find each other — a physical limit we must state honestly.

## Decision
- Every app is a **listener** (TCP 47100 signaling WS, UDP 47100 + TCP 47101 embedded STUN/TURN, UDP 47102 LAN
  discovery) and a **dialer**.
- Reachability, in order: LAN discovery → IPv6 → host reachable via UPnP-IGD / PCP / NAT-PMP auto-mapping or manual
  forward (the host's *own* embedded TURN lets a viewer behind any NAT through) → reverse connection (the controlled
  side dials out) → optional, off-by-default public STUN.
- The embedded TURN only relays to the listener's own machine and only for live sessions; it forwards ciphertext.
- Addresses travel in invite links / `ID@address` / the address book; the ID is a key fingerprint, not a locator.

## Alternatives Considered
- **Central hub (signaling + TURN + fleet)** — best connectivity, AnyDesk-like 9-digit IDs; violates the core
  requirement. Rejected.
- **Decentralized DHT (BitTorrent Mainline BEP 44, signed records)** — solves dynamic IPs without an operator, but
  still contacts third-party nodes. Deferred to v0.2 as an explicit opt-in.
- **Manual SDP copy-paste** — no network dependency at all, terrible UX. Rejected.

## Consequences
- No infrastructure, no accounts, nothing to subpoena or breach centrally.
- Case 5 (both sides behind CGNAT without IPv6) cannot connect unless the user opts into public STUN or a VPN.
- Dynamic IPs require re-sharing an invite (until the optional DHT lands).
- The app exposes an internet-facing port → strict listener hardening (PROTOCOL §8), memory-safe Dart parsers.
