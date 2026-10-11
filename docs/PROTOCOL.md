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
  - an **invite link** `thelxis://connect?id=<ID>&n=<url-encoded name>&a=<addr>,<addr>,…[&g=<gateway addr>,…]`
    (`g` = office gateways that can reach this device, §11).
  - a **connection code** `TX1.…` (§12).
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
- **Listener** iceServers: none (plus public STUN, below).
- **Public STUN** (setting, **on by default** since 0.1.1; the user can turn it off): both sides add
  `stun:stun.l.google.com:19302` and `stun:stun.cloudflare.com:3478`. A STUN server only learns the devices' public
  IP:port so their NATs can be punched; it never sees any session data.
- `bundlePolicy: max-bundle`. No other servers ever.
- The embedded TURN (listener side) MUST accept credentials only for live sessions (+60 s), and MUST only
  grant permissions/channels to peer addresses that are **local addresses of the listener's own machine**
  (it is a traversal aid for this session, never an open relay).

## 5. WebRTC session layout
- Host creates the PeerConnection, adds **one `sendonly` video transceiver** (no track yet) and three data channels:
  `"control"`, `"input"` and `"files"` (all ordered, reliable). Then the signed offer.
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
     "permissions":{"view":true,"control":true,"clipboard":true,"files":true,"audio":false}}
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

### 6.4 Files (channel `files`)
Text frames are JSON; binary frames are file data. The host enforces `permissions.files` for every request
coming from the viewer (`fs_*`, `get`, viewer-initiated `put`); without it → `fs_err`/`reject` with `denied`.

Remote browsing (viewer → host):
```
V→H {"t":"fs_roots","rid":1}
H→V {"t":"fs_roots_r","rid":1,"items":[{"name":"Home","path":"/Users/bob"},{"name":"Desktop","path":"…"},
                                         {"name":"Downloads","path":"…"},{"name":"C:\\","path":"C:\\"}]}
V→H {"t":"fs_list","rid":2,"path":"/Users/bob/Documents"}
H→V {"t":"fs_list_r","rid":2,"path":"…","items":[{"name":"a.pdf","dir":false,"size":1234,"mtime":1760000000}]}
H→V {"t":"fs_err","rid":2,"code":"not_found"|"denied"|"io","message":"…"}
```
Transfers (either direction). `xid` is chosen by the side that starts the transfer: **odd = viewer, even = host**.
```
S→R {"t":"put","xid":7,"name":"report.pdf" | "folder/sub/file.txt","size":123,"mtime":1760000000,"dest":null|"<dir>"}
V→H {"t":"get","xid":9,"path":"/Users/bob/Documents/a.pdf"}       → host answers with put(xid 9) or reject
R→S {"t":"accept","xid":7,"offset":0}                              offset > 0 resumes an existing .part file
R→S {"t":"reject","xid":7,"reason":"denied"|"exists"|"no_space"|"io"}
S→R binary frame: [uint32 big-endian xid][payload ≤ 65 536 bytes]  — sequential, offsets implicit
S→R {"t":"done","xid":7,"sha256":"<hex of the whole file>"}
R→S {"t":"ok","xid":7}  |  {"t":"fail","xid":7,"reason":"hash"|"io"}
X→Y {"t":"cancel","xid":7}
```
- `dest: null` → receiver's incoming folder (`<Downloads>/Thelxis`). A viewer browsing the host may set `dest` to a
  directory it listed. Folders are sent as individual files whose `name` holds a relative path.
- The receiver writes to `<name>.thelxis-part`, verifies size + SHA-256, then renames (adds ` (1)`, ` (2)`… on clash)
  and restores `mtime`. **Name sanitization is mandatory**: reject absolute paths, drive letters, `..` segments,
  NUL/control characters, and Windows-reserved names; never follow symlinks out of the destination.
- One data stream per direction at a time (queue); the sender pauses while the channel's `bufferedAmount` > 1 MiB.
- Optional fields (ignored by older peers): `fs_roots_r.items[].kind` ∈ `home|desktop|documents|downloads|drive|storage`
  (lets the viewer localize labels); paging `fs_list.offset`/`limit` → `fs_list_r.offset`/`total`, and
  `fs_list_r.items[].hidden`. Hosts keep each JSON reply ≤ 180 KiB (SCTP messages are capped at 256 KiB).
- Only a host honors `put.dest`, and only for an existing absolute directory; a viewer ignores `dest` and the host's
  `name` when answering its own `get`. UNC, relative and `..` paths are rejected for `dest`, `fs_list` and `get`.
  A `get` for a missing/unreadable file is answered with `reject` reason `io`.
- Clipboard (§6.2 `clipboard`) carries text in v0.1; images/file lists are v0.2.

## 7. LAN discovery (UDP 47102)
```
viewer → 255.255.255.255:47102 and each interface broadcast:  {"t":"discover","v":2}
host   → unicast reply:  {"t":"here","v":2,"id":"K7M2P9XQ4TAB8HDE","key":"<b64url>","name":"Office PC","os":"windows","port":47100,
                          "gateway":true|absent,"gw_addresses":["203.0.113.5:47110"]|absent}
```
Viewers re-broadcast every 5 s while the Devices screen is visible; entries expire after 15 s without a reply.

## 8. Listener hardening (the signaling port may face the internet)
- Max 4 unauthenticated connections per remote IP, 30 new handshakes per minute overall; excess → `rate_limited`.
- Max frame 1 MiB; malformed JSON → close. Idle unauthenticated connection → close after 10 s.
- `allow incoming` off → the listener, TURN and port mappings are all shut down.
- Never log keys' private parts, passwords, proofs, TURN credentials, SDP, or clipboard contents.

## 9. Session badge (host UI requirement)
While ≥ 1 incoming session is active, the host shows a native always-on-top frosted-glass badge in a screen
corner: Thelxis logo, viewer name(s), elapsed time, Stop button. It cannot be hidden or disabled; Stop ends the
sessions. Where the OS allows, the badge window is excluded from screen capture (it is for the local user).

## 10. Over-the-air updates
The only non-peer endpoint the app ever contacts, and only if "Automatic updates" is enabled (default on).
```
GET https://github.com/boopi-coder/thelxis/releases/latest/download/update.json
GET https://github.com/boopi-coder/thelxis/releases/latest/download/update.json.sig
update.json = {"v":1,"version":"0.2.0","published":"2026-10-20T10:00:00Z",
               "notes_url":"https://github.com/boopi-coder/thelxis/releases/tag/v0.2.0",
               "assets":{"windows-x64":{"name":"…-setup.exe","url":"https://…","size":123,"sha256":"<hex>"},
                         "macos-universal":{…dmg}, "linux-x64-deb":{…}, "linux-x64-tar":{…},
                         "android-arm64-v8a":{…}, "android-armeabi-v7a":{…}, "android-x86_64":{…},
                         "android-universal":{…}}}
update.json.sig = base64url(Ed25519 signature over the exact bytes of update.json)
```
- Verify the signature with the public key in `app/lib/update/update_trust.dart` **before parsing**; then require
  `version` > current (semver; pre-releases ignored), download the asset for this platform/ABI/install type, verify
  size + SHA-256, install. Any mismatch → discard and report; never fall back to an unsigned path.
- Never install while a session is active; defer until idle. Check 30 s after start and every 6 h.

## 11. Office gateway (since 0.2)
One reachable device (gateway **G**, setting "Office gateway", off by default) gives outside viewers a way to every
Thelxis device in its LAN (targets **T**) through **one** forwarded port. G is a blind pipe: the viewer **V** still
performs the §4.1 handshake *with T* and the media is DTLS-encrypted end-to-end between V and T.

- No extra opt-in on T: a connection through G is equivalent to a LAN connection, and T authorizes V itself (§6.1).
- V dials `ws://<G address>/thelxis/via/<T ID without dashes>` (hello as usual, `dialed` = the G address).
- G looks T up in its LAN discovery table (entries ≤ 15 s old; otherwise re-discovers for up to 2 s). Not found →
  `{"t":"error","code":"not_found"}` and close. Else G opens `ws://<T LAN address>:<port>/thelxis` and **pipes frames
  unchanged in both directions**, with one exception: in a frame from T with `t == "session"`, G replaces `turn` with
  its own **gateway grant** (`issueTurnGrant(dialedAddress: V.dialed, gateway: true)`), because T's TURN is not
  reachable from outside. V builds TURN URLs from the G address it dialed, as in §4.3.
- A gateway grant may create permissions/channels for G's own addresses **and** private (RFC 1918) addresses inside
  G's directly connected IPv4 subnets — nothing else.
- V MUST verify T's ID (no trust-on-first-use through a gateway unless the user explicitly confirms the ID).
- Limits on G: §8 rules, at most 16 concurrent pipes, a pipe closes when either side closes. A dropped pipe is
  resumed like any signaling drop (§4.2 `resume`) by dialing G again.
- G advertises itself in discovery (`gateway`, `gw_addresses`). T adds those addresses as `g=` to its invites; dialers
  race direct addresses first and gateway routes 500 ms later.

## 12. Connect by code (since 0.2)
For when neither side's signaling port is reachable (e.g. grey IPs on both sides): two short texts are exchanged by the
users over any channel they choose; together with public STUN this punches both NATs (carrier-grade NATs keep
endpoint-independent mappings per RFC 6888).
```
offer code  (host → viewer)  = "TX1." + base64url(deflate(utf8(JSON)))
  {"v":1,"k":"<host key>","n":"<name>","os":"…","nonce":"<nH>","exp":<unix+600>,"sdp":"<offer, ICE gathering complete>",
   "sig":"<Ed25519_H(\"thelxis-code-v1|offer|\" + nH + \"|\" + exp + \"|\" + sdp)>"}
answer code (viewer → host) = "TX2." + base64url(deflate(utf8(JSON)))
  {"v":1,"k":"<viewer key>","n":"<name>","os":"…","nonce":"<nV>","sdp":"<answer, ICE gathering complete>",
   "sig":"<Ed25519_V(\"thelxis-code-v1|answer|\" + nH + \"|\" + nV + \"|\" + sdp)>"}
```
- The code creator is always the **host** (it offers control of itself). It builds the PeerConnection exactly as §5
  (with public STUN), waits for ICE gathering to complete (max 5 s) and shows the code (text + QR). Codes are single-use,
  expire after 10 minutes, and a host keeps at most 3 pending offers.
- The viewer verifies the signature and shows the host's ID for confirmation (TOFU, or must match a known ID), answers,
  and shows the answer code; the host verifies the answer signature and `nH`, then applies it.
- Authorization afterwards is §6.1, unchanged.
- **In-band signaling:** sessions created by code have no WebSocket, so later signaling (ICE-restart offers/answers,
  candidates) travels on the `control` channel as `{"t":"rtc","data":{…§4.2 signal data…}}`, SDP signatures using
  `"thelxis-sdp-v2|" + nH + "|" + nV + "|" + type + "|" + sdp`. Hosts accept `rtc` only from an authorized viewer or
  for ICE restarts of the current session.
