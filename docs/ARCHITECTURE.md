# Thelxis — Architecture

> **Thelxis** (Θέλξις, Greek: "enchantment, spellbinding") — the power Hermes' wand had over the eyes of men.
> Hermes was also the messenger god. A remote-control product that "charms" a device from afar.

Thelxis is a cross-platform remote desktop for **Windows, macOS, Linux and Android**: one app that is both
**host** (being controlled) and **viewer** (controlling). **There is no server of any kind** — no hub, no
accounts, no relay operated by anyone. Two devices connect directly; encryption keys exist only on them.

## Goals (why another remote desktop)

1. **Zero intermediaries.** PC ↔ PC. No company server, no user-run server, no account. Nothing in between can
   decrypt, record, or even see who talks to whom (except the network path itself).
2. **Never freeze.** WebRTC (libwebrtc — the engine of Chrome/Meet): congestion control (GCC/transport-cc),
   NACK/PLI/FEC, jitter buffer, hardware codecs, adaptive bitrate, ICE restart on network change.
3. **Security by construction.** Identity = Ed25519 key; the Thelxis ID is its fingerprint. The handshake and every
   SDP are signed, so DTLS-SRTP is bound to both identities (no MITM possible). Passwords never travel
   (session-bound proof). Host always shows who is connected and can stop it instantly.
4. **Enterprise-grade without a server.** Trusted Devices (like SSH authorized_keys) for unattended access,
   per-device permissions, address book with notes/tags, deployable config files for fleets.
5. **Works on a LAN/VPN with zero setup**; over the internet as long as one side is reachable.

## Connectivity ladder (all serverless)

| # | Situation | How it connects |
|---|---|---|
| 1 | Same LAN / VPN (Tailscale, ZeroTier, WireGuard) | UDP discovery, direct host candidates |
| 2 | Both have IPv6 | direct IPv6, both sides send ICE checks (stateful firewalls open) |
| 3 | Host reachable: public IP, UPnP/NAT-PMP/PCP auto-mapping, or manual forward of 47100/tcp+udp, 47101/tcp | viewer dials host; host's **embedded STUN/TURN** lets the viewer through any NAT; media stays E2E |
| 4 | Only the viewer is reachable | **reverse connection**: the controlled side dials out (`want: be_controlled`), using the viewer's embedded TURN |
| 5 | Both behind carrier-grade NAT, no IPv6 | not possible without a third party → optional "Public STUN" toggle (off by default; reveals only IPs to the STUN server) or a VPN overlay |

The embedded TURN only relays to the listener's own machine (never an open relay); it carries
already-encrypted DTLS packets, so even this hop on the device itself sees only ciphertext until libwebrtc.

## Components

```
┌──────────────────────── Thelxis App (Flutter, one codebase) ─────────────────────────┐
│ UI (Material 3) — Home · Devices · Sessions · Settings                               │
│ Core: identity (Ed25519, Thelxis ID) · settings · address book · trusted devices     │
│ Net:  Listener (WS :47100) · Dialer (happy eyeballs) · LAN discovery (UDP :47102)    │
│       Connectivity: UPnP-IGD / NAT-PMP / PCP mapper · embedded STUN/TURN (:47100/udp, │
│       :47101/tcp) · reachability report (LAN, IPv6, external IP, CGNAT detection)    │
│ Session: HostSession / ViewerSession (flutter_webrtc / libwebrtc, DTLS-SRTP)          │
│ Platform: HostPlatform → InputInjector + displays + permissions + capture services   │
│   windows: FFI SendInput · macos: CGEvent · linux: FFI XTest · android: Accessibility │
└──────────────────────────────────────────────────────────────────────────────────────┘
                 ▲                      WebRTC P2P, E2E                      ▲
                 └──────────────────── (no servers) ─────────────────────────┘
```

- Screen capture, encoding, transport and decoding: `flutter_webrtc` (libwebrtc, C++).
- Input injection: native per OS behind `lib/platform/host_platform.dart`.
- Connectivity: pure Dart behind `lib/net/connectivity/connectivity.dart`.
- **Protocol** — `docs/PROTOCOL.md` (v2) is the contract.

## Session lifecycle

1. Viewer picks a target: LAN device, address-book entry, invite link, `ID@address`, or bare address (TOFU).
2. Dialer opens `ws://addr:47100/thelxis` (all addresses in parallel), signed handshake proves both identities,
   listener issues one-time TURN credentials for its embedded TURN.
3. Host builds the PeerConnection (`sendonly` video transceiver, `control` + `input` channels) and sends a signed
   offer; viewer sends a signed answer; trickle ICE.
4. Authorization over the encrypted `control` channel: trusted key | password proof | accept prompt.
5. Host captures the selected display and `replaceTrack`s it in; input/clipboard/control flow.
6. Network change → ICE restart; WS dropped → dialer resumes signaling; host releases keys on end.

## UX concept

Modern, calm, dark-first (Material 3, seed `#6C4CF5` deep violet, spiral logo). Desktop: navigation rail +
session tabs. Android: bottom navigation.

- **Home ("This device")** — big card: **Thelxis ID** `K7M2-P9XQ-4TAB-8HDE` (copy), one-time password
  (show/refresh), reachability pill (Reachable from internet · LAN only · Not accepting) with a "why?" link to
  diagnostics, *Allow incoming* switch, **Share access** button (invite link + QR + copyable `ID@address`),
  a **Connect** field and recent connections as chips. While controlled: a persistent banner
  "Controlled by Alice — Stop".
- **Devices** — address book (favorites, tags, notes, last addresses, last seen) + LAN-discovered devices.
  `Ctrl/⌘+K` command palette; row actions: Connect, View only, Edit, Remove. Import/export (JSON).
- **Sessions** — active incoming/outgoing sessions and local history.
- **Settings** — Security (permanent password, require approval, **Trusted Devices** list with permissions and
  revoke, default permissions), Connectivity (allow incoming, UPnP auto-mapping, LAN discovery, Public STUN
  opt-in, **diagnostics**: LAN IPs, IPv6, router/UPnP status, external IP, CGNAT warning, mapped ports),
  Appearance, Startup, About.
- **Session view** — remote screen edge-to-edge; floating auto-hiding toolbar pill: display switcher, quality,
  special keys, clipboard sync, view-only, fit/1:1/fullscreen, stats (RTT, fps, bitrate, loss, codec, path:
  LAN / IPv6 / Direct / Via host TURN), chat, End. Android viewer: Touchpad + Direct touch modes, pinch-zoom,
  extra-keys row. Reconnecting overlay instead of a frozen frame.
- **Prompts** — incoming control request (who, verified ID, permissions, "Always allow this device", 30 s);
  reverse offer ("Bob offers you control of his PC"); first-contact ID confirmation (TOFU); identity-mismatch
  security warning.

## Platform notes / known limits (v0.1)

| | Host capture | Host input | Viewer | Notes |
|---|---|---|---|---|
| Windows | ✔ libwebrtc (DXGI/GDI) | ✔ SendInput (FFI) | ✔ | Elevated windows/UAC need admin/service (v0.2) |
| macOS | ✔ (Screen Recording permission) | ✔ CGEvent (Accessibility permission) | ✔ | Unsigned builds: right-click → Open |
| Linux | ✔ X11 (PipeWire if available) | ✔ X11 XTest; ✖ Wayland input (v0.2: libei/portal) | ✔ | |
| Android | ✔ MediaProjection + FGS | ✔ AccessibilityService gestures | ✔ | User enables the accessibility service |

## Roadmap

- **v0.1** — serverless P2P, signed handshake, embedded STUN/TURN, UPnP/NAT-PMP, LAN discovery, invite links,
  password/request/trusted auth, control, multi-monitor, clipboard text, quality presets, stats, address book,
  CI releases for all platforms.
- **v0.2** — Windows service / macOS LaunchDaemon for unattended login-screen access, file transfer, chat UI,
  Wayland input, audio, opt-in decentralized address lookup (DHT, signed records) for dynamic IPs, auto-update.
- **v0.3** — signed fleet policy files (admin key), session recording (local), 2FA on host, iOS viewer.

Decisions are recorded in `docs/decisions/`.
