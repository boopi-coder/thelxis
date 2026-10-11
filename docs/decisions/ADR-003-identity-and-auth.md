# ADR-003: Ed25519 device identity, signed SDP binding, session-bound password proofs

## Status
Accepted

## Date
2026-10-11

## Context
Signaling runs over plain WebSockets between peers (no CA, no server). We need: no MITM, no password exposure,
unattended access without shared secrets, and IDs humans can compare.

## Decision
- Device identity = Ed25519 key pair generated on device; **Thelxis ID** = Crockford-Base32 of the first 80 bits of
  SHA-256(public key), shown as `XXXX-XXXX-XXXX-XXXX`.
- Handshake: both sides sign each other's nonces + the peer key; every SDP (which carries the DTLS fingerprint) is
  signed. DTLS-SRTP is therefore bound to both identities — an attacker on the path can relay bytes but cannot
  read or alter them.
- Authorization over the encrypted channel: **trusted** (viewer key in the host's Trusted Devices, like SSH
  `authorized_keys`), **password** (PBKDF2 key + HMAC proof over the session's DTLS fingerprints — the password
  never travels and a captured proof is useless elsewhere), or **request** (host user accepts).
- Connecting to a bare address = trust-on-first-use with an explicit ID confirmation; known IDs are pinned.

## Alternatives Considered
- **TLS with self-signed certs** — same trust problem (pinning), more moving parts. Rejected.
- **SRP/PAKE for passwords** — stronger against offline guessing by an active MITM, but the MITM is already excluded
  by signed SDP; PBKDF2+HMAC is simpler to implement identically in Dart everywhere. Revisit if needed.

## Consequences
- 80-bit fingerprints: second-preimage forgery infeasible; IDs are longer than AnyDesk's 9 digits.
- Losing the device key = new ID; trusted relationships must be re-established (by design).
