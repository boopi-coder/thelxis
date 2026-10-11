# Thelxis Protocol v2 — serverless

This document is the **contract** between all parts of the Thelxis app. Implement it exactly.
Any change requires bumping `v` and updating this file first.

**There is no server of any kind.** No hub, no accounts, no third-party relay. Two Thelxis apps talk
directly. Every app is a *listener* (accepts connections) and can be a *dialer* (opens connections).
Each app embeds its own STUN/TURN responder so that a peer behind any NAT can reach it, as long as
**one** of the two sides is reachable. Media and data are end-to-end encrypted (DTLS-SRTP) and the
encryption is bound to the devices' identity keys — nothing in between can decrypt or impersonate.

Conventions: JSON over UTF-8 text frames; every message has a type field `t`; unknown fields and unknown
`t` values MUST be ignored. Binary values are **base64url without padding**. Times are Unix seconds.

---

## 1. Identity

- Every install generates an **Ed25519 key pair** on first launch. The private key never leaves the device.
- `key` — 32-byte raw public key, base64url.
- **Thelxis ID** — `CrockfordBase32(SHA-256(public key raw)[0..10])` → 16 characters
  (alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`). Displayed as `K7M2-P9XQ-4TAB-8HDE`.
  Parsing: uppercase, drop `-` and spaces, map `I`/`L`→`1`, `O`→`0`.
  The ID is a cryptographic fingerprint (80 bits): it *verifies* a device; addresses *locate* it.

## 2. Ports (all on the device itself)

| Port | Purpose |
|---|---|
| TCP 47100 | Signaling — WebSocket, path `/thelxis` |
| UDP 47100 | Embedded STUN/TURN (UDP) |
| TCP 47101 | Embedded TURN over TCP (for networks that block UDP) |
| UDP 47102 | LAN discovery |

If a router mapping cannot use the same external port, the actual external port is advertised in addresses.
The TURN/STUN ports a peer must use are sent explicitly in §4.3, never assumed.

## 3. Addressing

- **Address** — `ip:port` or `[ipv6]:port` of a listener's signaling port (TCP 47100 or its external mapping).
- **Advertised addresses** (best first): external public IPv4 from UPnP/NAT-PMP/PCP mapping, global IPv6,
  LAN IPv4. Shown in the UI and embedded in invite links.
- **Connect target** forms the user may enter:
  - `ID@host[:port]` → connect and require that the peer's key matches the ID (mismatch = hard failure,
    "identity mismatch — possible interception").
  - `host[:port]` → trust-on-first-use: show the peer's ID and name and ask the user to confirm, then pin.
  - an **invite link** `thelxis://connect?id=<ID>&n=<url-encoded name>&a=<addr>,<addr>,…`.
  - an address-book entry or a LAN-discovered device.
- With multiple addresses the dialer tries them in parallel, staggered by 250 ms ("happy eyeballs");
  the first completed handshake with the expected ID wins, the rest are closed.

## 4. Signaling (WebSocket `ws://<address>/thelxis`)

One WebSocket = one session. The connection is plain WS; integrity comes from Ed25519 signatures over the
handshake and every SDP (the SDP contains the DTLS fingerprints, so the encrypted channel is bound to both keys).

### 4.1 Handshake
```
D→L {"t":"hello","v":2,"role":"dialer","key":"<D key>","name":"MacBook","os":"macos","app":"0.1.0",
     "want":"control" | "be_controlled","nonce":"<nD 32B>","addresses":["…"],
     "dialed":"203.0.113.5:47100"}
L→D {"t":"hello","v":2,"role":"listener","key":"<L key>","name":"Office PC","os":"windows","app":"0.1.0",
     "nonce":"<nL 32B>","addresses":["…"],
     "sig":"<Ed25519_L( \"thelxis-hs-v2|listener|\" + nD + \"|\" + nL + \"|\" + D.key )>"}
D→L {"t":"hello_ack","sig":"<Ed25519_D( \"thelxis-hs-v2|dialer|\" + nD + \"|\" + nL + \"|\" + L.key )>"}
L→D {"t":"session","sid":"<uuid>",
     "turn":{"username":"<random 16B b64url>","credential":"<random 24B b64url>","udp_port":47100,"tcp_port":47101} | null}
   or at any point:
X→Y {"t":"error","code":"not_accepting"|"bad_signature"|"version"|"rate_limited"|"busy","message":"…"}  (then close)
```
- `want: "control"` — the dialer wants to control the listener (dialer = **viewer**, listener = **host**).
- `want: "be_controlled"` — reverse/invite mode: the dialer offers control of itself (dialer = **host**,
  listener = **viewer**). Used when the controlled device is not reachable but the helper is.
- Signatures are over the UTF-8 bytes of the shown strings (`nD`, `nL`, keys as base64url text).
- `addresses` let each side remember how to reach the other next time (address book).
- `dialed` is the exact address the dialer connected to; the listener uses it to decide whether to hand out its
  external (router-mapped) or local TURN ports.
- The listener verifies `hello_ack` before revealing anything else; the dialer verifies the listener's `sig`
  and the expected ID before sending `hello_ack`.
- Timeouts: `hello` within 10 s of connect; whole handshake within 20 s.

### 4.2 WebRTC signaling
```
X→Y {"t":"signal","data":{"type":"offer"|"answer","sdp":"…",
                           "sig":"<Ed25519_X( \"thelxis-sdp-v2|\" + nD + \"|\" + nL + \"|\" + type + \"|\" + sdp )>"}}
X→Y {"t":"signal","data":{"type":"candidate","candidate":"candidate:…","sdpMid":"0","sdpMLineIndex":0}}
X→Y {"t":"bye","reason":"user"|"denied"|"error"|"timeout"}
X→Y {"t":"ping"}  /  {"t":"pong"}          every 20 s; close after 60 s of silence
```
- The **host** (controlled side) creates the offer; the viewer answers. ICE restarts are new signed offers.
- An SDP whose signature fails → `bye` with reason `error`, close, and show a security warning.
- **The session survives a WebSocket drop** (media is independent). The dialer reconnects with a fresh §4.1
  handshake whose hello carries `"resume":"<sid>"`; the listener re-attaches it to the live session.

### 4.3 ICE configuration
- **Dialer** iceServers: if `turn` was given:
  `{"urls":["stun:<H>:<udp_port>"]}` and
  `{"urls":["turn:<H>:<udp_port>?transport=udp","turn:<H>:<tcp_port>?transport=tcp"],"username":…,"credential":…}`
  where `<H>` is the host/IP the dialer actually connected to (bracketed for IPv6).
- **Listener** iceServers: none.
- Either side MAY add a public STUN server **only if the user enabled** "Public STUN" (off by default).
- `bundlePolicy: max-bundle`. No other servers ever.
- The embedded TURN (listener side) MUST accept credentials only for live sessions (+60 s), and MUST only
  grant permissions/channels to peer addresses that are **local addresses of the listener's own machine**
  (it is a traversal aid for this session, never an open relay).

## 5. WebRTC session layout
- Host creates the PeerConnection, adds **one `sendonly` video transceiver** (no track yet) and two data channels:
  `"control"` (ordered, reliable) and `"input"` (ordered, reliable). Then the signed offer.
- **No video is attached until authorization succeeds** (§6.1). Then `sender.replaceTrack(screenTrack)`;
  switching displays = another `replaceTrack` (no renegotiation).
- `iceConnectionState == disconnected` > 3 s → host does an ICE restart; `failed` > 20 s → session ends.

## 6. Data channel messages

### 6.1 Authorization (channel `control`)
Both identities are already proven by §4.1. Authorization decides whether this viewer may control this host.
```
H→V {"t":"hello","v":2,"methods":["trusted","password","request"],"nonce":"<32B>"}
V→H {"t":"auth","method":"trusted"}                          host checks V.key in its Trusted Devices
V→H {"t":"auth","method":"password","proof":"<b64url>"}
V→H {"t":"auth","method":"request","user":"Alice"}           host user gets an Accept/Deny prompt (30 s)
H→V {"t":"auth_result","ok":true,"trusted":true|false,
     "permissions":{"view":true,"control":true,"clipboard":true,"files":false,"audio":false}}
H→V {"t":"auth_result","ok":false,"reason":"bad_password"|"denied"|"locked"|"not_trusted"|"not_allowed","retry":true|false}
```
- `methods` lists only what the host currently allows. A viewer that believes it is trusted tries `trusted`
  first and falls back to the other methods on `not_trusted`.
- Accept prompt has an "Always allow this device" checkbox → host adds V.key to Trusted Devices
  (`auth_result.trusted = true`). Password success may also offer it.
- **Password proof** (the password never travels; proof is bound to this DTLS session):
  ```
  salt  = UTF-8("thelxis-pw-v1:" + host ID without dashes)
  key   = PBKDF2-HMAC-SHA256(UTF-8(password), salt, 60000 iterations, 32 bytes)
  fp_a, fp_b = the two "a=fingerprint:" values (local + remote SDP, e.g. "sha-256 AB:CD:…", uppercase), sorted ascending
  msg   = UTF-8("thelxis-auth-v1|" + nonce + "|" + fp_a + "|" + fp_b)
  proof = HMAC-SHA256(key, msg)
  ```
  The host stores only `key` for the permanent password. The one-time password is shown in the UI and rotated
  after each successful session. 5 failures → password auth locked for 5 minutes (`locked`).

### 6.2 Control (channel `control`, after authorization)
```
H→V {"t":"displays","items":[{"id":"0","name":"Display 1","width":2560,"height":1440,"primary":true}],"active":"0"}
V→H {"t":"select_display","id":"1"}
V→H {"t":"quality","preset":"auto"|"speed"|"balanced"|"quality"}
        auto     = no caps, degradation "balanced"
        speed    = max 30 fps, maxBitrate 2.5 Mbps, degradation "maintain-framerate"
        balanced = max 30 fps, maxBitrate 6 Mbps, degradation "balanced"
        quality  = max 60 fps, no bitrate cap, degradation "maintain-resolution"
X→Y {"t":"clipboard","text":"…"}               only if permissions.clipboard; max 1 MiB
X→Y {"t":"chat","text":"…"}
H→V {"t":"permissions","permissions":{…}}      live change, e.g. control revoked
X→Y {"t":"bye","reason":"user"|"timeout"|"error"}
```

### 6.3 Input (channel `input`, viewer → host, only if permissions.control)
Coordinates are normalized to the active display (0.0–1.0, origin top-left).
```
{"t":"mm","x":0.5123,"y":0.2211}                 mouse move (absolute)
{"t":"md","b":0,"x":0.51,"y":0.22}               button down; b: 0 left, 1 middle, 2 right, 3 back, 4 forward
{"t":"mu","b":0,"x":0.51,"y":0.22}               button up
{"t":"wh","dx":0.0,"dy":60.0}                    wheel, logical px; dy>0 = content scrolls down; 60 px ≈ 1 notch
{"t":"kd","c":458756}                             key down; c = USB HID usage (page<<16 | id), 0x00070004 = KeyA
{"t":"ku","c":458756}                             key up
{"t":"txt","s":"Привет"}                         unicode text (soft keyboards / IME)
{"t":"sp","a":"ctrl_alt_del"|"lock"|"back"|"home"|"recents"|"notifications"|"power"}
```
The host tracks pressed keys/buttons and releases all of them when the session ends or control is revoked.

## 7. LAN discovery (UDP 47102)
```
viewer → 255.255.255.255:47102 and each interface broadcast:  {"t":"discover","v":2}
host   → unicast reply:  {"t":"here","v":2,"id":"K7M2P9XQ4TAB8HDE","key":"<b64url>","name":"Office PC","os":"windows","port":47100}
```
Viewers re-broadcast every 5 s while the Devices screen is visible; entries expire after 15 s without a reply.

## 8. Listener hardening (the signaling port may face the internet)
- Max 4 unauthenticated connections per remote IP, 30 new handshakes per minute overall; excess → `rate_limited`.
- Max frame 1 MiB; malformed JSON → close. Idle unauthenticated connection → close after 10 s.
- `allow incoming` off → the listener, TURN and port mappings are all shut down.
- Never log keys' private parts, passwords, proofs, TURN credentials, SDP, or clipboard contents.
