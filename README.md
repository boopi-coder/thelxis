<p align="center">
  <img src="app/assets/icon/app_icon.png" alt="Thelxis" width="128" height="128">
</p>

<h1 align="center">Thelxis</h1>

<p align="center">
  <b>Удалённый рабочий стол без серверов.</b> Прямое зашифрованное соединение компьютер - компьютер.<br>
  <b>Remote desktop with no servers.</b> Direct, end-to-end encrypted PC-to-PC connection.
</p>

<p align="center">
  <a href="https://github.com/sibawal/thelxis/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/sibawal/thelxis/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/sibawal/thelxis/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/sibawal/thelxis?include_prereleases"></a>
</p>

[Русский](#русский) | [English](#english)

---

## Русский

### Что это

**Thelxis** — кроссплатформенный удалённый рабочий стол для **Windows, macOS, Linux и Android**. Одно приложение
работает и как *хост* (им управляют), и как *зритель* (вы управляете). Между двумя устройствами нет ничего:
**ни сервера, ни аккаунта, ни чьего-то реле**. Ключи шифрования существуют только на ваших устройствах.

### Почему «Thelxis»

**Θέλξις** (thelxis) по-гречески — «очарование, завораживание». Так называли силу жезла Гермеса, которым он
усыплял и завораживал взгляд людей. Гермес — ещё и бог-вестник, посланник. Продукт, который «зачаровывает»
устройство на расстоянии, получил имя от этой силы, а логотип — гипнотическая спираль.

### Возможности

- **Без посредников**: прямое P2P-соединение (WebRTC, DTLS-SRTP), никаких серверов и учётных записей.
- **Не зависает**: движок libwebrtc (как в Chrome/Meet) — контроль перегрузки, NACK/PLI/FEC, адаптивный битрейт,
  аппаратные кодеки, перезапуск ICE при смене сети.
- **Безопасность по построению**: идентичность — ключ Ed25519, Thelxis ID — его отпечаток; рукопожатие и каждый SDP
  подписаны, поэтому подмена канала (MITM) невозможна. Пароль по сети не передаётся. Хост всегда видит, кто
  подключён, и может мгновенно отключить.
- **Подключение за любым роутером**: автообнаружение в LAN -> IPv6 -> проброс портов UPnP/NAT-PMP/PCP -> обратное
  соединение; в каждом приложении встроены STUN/TURN (см. таблицу ниже).
- **Управление**: мышь, клавиатура, несколько мониторов, буфер обмена (текст), пресеты качества, статистика
  (RTT, fps, битрейт, потери, тип пути).
- **Доверенные устройства** для доступа без присутствия (как `authorized_keys` в SSH), права по устройствам,
  адресная книга с заметками и тегами, ссылки-приглашения и QR.
- **Платформы**: Windows, macOS (Apple Silicon и Intel), Linux (X11), Android (хост и зритель).

### Как устанавливается соединение

| # | Ситуация | Как подключаемся |
|---|---|---|
| 1 | Одна LAN / VPN (Tailscale, ZeroTier, WireGuard) | UDP-обнаружение, прямые адреса |
| 2 | У обоих есть IPv6 | прямой IPv6 |
| 3 | Хост доступен: публичный IP, авто-проброс UPnP/NAT-PMP/PCP или ручной проброс 47100/tcp+udp, 47101/tcp | зритель подключается к хосту; встроенный STUN/TURN хоста пропускает через любой NAT |
| 4 | Доступен только зритель | **обратное соединение**: управляемая сторона сама подключается к зрителю |
| 5 | Оба за CGNAT и без IPv6 | без третьей стороны невозможно: опциональный публичный STUN (по умолчанию выключен) или VPN-оверлей |

Порты (на самом устройстве):

| Порт | Назначение |
|---|---|
| 47100/tcp | сигнализация (WebSocket) |
| 47100/udp | встроенный STUN/TURN |
| 47101/tcp | TURN поверх TCP (сети, блокирующие UDP) |
| 47102/udp | обнаружение в локальной сети |

### Архитектура

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

Подробнее: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), протокол: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

### Скачать

Готовые сборки для всех платформ — на странице **[Releases](https://github.com/sibawal/thelxis/releases/latest)**:

| Платформа | Файлы |
|---|---|
| Windows | установщик `Thelxis-<версия>-windows-x64-setup.exe`, архив `Thelxis-<версия>-windows-x64.zip` |
| macOS | `Thelxis-<версия>-macos-universal.dmg` |
| Linux | `thelxis_<версия>_amd64.deb`, `Thelxis-<версия>-linux-x64.tar.gz` |
| Android | `Thelxis-<версия>-android-<abi>.apk` или `...-universal.apk` |

Сборки не подписаны сертификатом разработчика — инструкции по первому запуску (SmartScreen, Gatekeeper, права
macOS, служба специальных возможностей Android) приведены в описании каждого релиза.

### Сборка из исходников

Нужен Flutter 3.47 (Dart 3.13). Для нативных сборок — тулчейн целевой платформы: Visual Studio (C++ desktop) на
Windows, Xcode на macOS, `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libx11-dev libxi-dev` на Linux
(Ubuntu 22.04+), JDK 17 и Android SDK для Android.

```bash
cd app
flutter pub get
flutter analyze && flutter test
flutter run -d macos          # или windows / linux / <android-устройство>
flutter build apk --release   # или: macos | windows | linux
```

Иконки: `packaging/icons/generate.sh` (Python 3 + Pillow + numpy) заново рисует логотип и обновляет иконки платформ.
Релиз выпускается тегом: см. [`packaging/README.md`](packaging/README.md).

### Структура репозитория

```
app/          Flutter-приложение (Windows, macOS, Linux, Android)
docs/         архитектура, протокол, решения
packaging/    иконки, установщик Windows (Inno Setup), сборка .deb, шаблон описания релиза
.github/      GitHub Actions: CI и выпуск релизов
```

### Дорожная карта

- **v0.1** — P2P без серверов, подписанное рукопожатие, встроенные STUN/TURN, UPnP/NAT-PMP, LAN-обнаружение,
  ссылки-приглашения, вход по паролю / запросу / доверенному ключу, управление, несколько мониторов, буфер обмена,
  пресеты качества, статистика, адресная книга, релизы под все платформы.
- **v0.2** — служба Windows / LaunchDaemon macOS для доступа к экрану входа, передача файлов, чат, ввод в Wayland,
  звук, опциональный децентрализованный поиск адреса (DHT, подписанные записи) для динамических IP, автообновление.
- **v0.3** — подписанные файлы политик для парков устройств, локальная запись сессий, 2FA на хосте, зритель для iOS.

---

## English

### What it is

**Thelxis** is a cross-platform remote desktop for **Windows, macOS, Linux and Android**. One app is both the
*host* (being controlled) and the *viewer* (controlling). Between two devices there is nothing: **no server, no
account, no relay run by anyone**. Encryption keys exist only on your devices.

### Why "Thelxis"

**Θέλξις** (thelxis) is Greek for "enchantment, spellbinding" - the power of Hermes' wand over the eyes of men.
Hermes was also the messenger god. A product that "charms" a device from afar took its name from that power, and
its logo is a hypnotic spiral.

### Features

- **No intermediaries**: direct P2P connection (WebRTC, DTLS-SRTP); no servers, no accounts.
- **Never freezes**: the libwebrtc engine (as in Chrome/Meet) - congestion control, NACK/PLI/FEC, adaptive bitrate,
  hardware codecs, ICE restart on network change.
- **Security by construction**: identity is an Ed25519 key and the Thelxis ID is its fingerprint; the handshake and
  every SDP are signed, so the encrypted channel is bound to both identities (no MITM). Passwords never travel.
  The host always shows who is connected and can cut them off instantly.
- **Connects behind any router**: LAN auto-discovery -> IPv6 -> UPnP/NAT-PMP/PCP port mapping -> reverse
  connection; every app embeds its own STUN/TURN (see the table below).
- **Control**: mouse, keyboard, multiple monitors, text clipboard, quality presets, live stats (RTT, fps,
  bitrate, loss, path type).
- **Trusted devices** for unattended access (like SSH `authorized_keys`), per-device permissions, an address book
  with notes and tags, invite links and QR codes.
- **Platforms**: Windows, macOS (Apple Silicon and Intel), Linux (X11), Android (host and viewer).

### How connections are made

| # | Situation | How it connects |
|---|---|---|
| 1 | Same LAN / VPN (Tailscale, ZeroTier, WireGuard) | UDP discovery, direct host candidates |
| 2 | Both have IPv6 | direct IPv6 |
| 3 | Host reachable: public IP, UPnP/NAT-PMP/PCP auto-mapping, or manual forward of 47100/tcp+udp and 47101/tcp | viewer dials the host; the host's embedded STUN/TURN gets the viewer through any NAT |
| 4 | Only the viewer is reachable | **reverse connection**: the controlled side dials out to the viewer |
| 5 | Both behind carrier-grade NAT, no IPv6 | not possible without a third party: optional public STUN (off by default) or a VPN overlay |

Ports (on the device itself):

| Port | Purpose |
|---|---|
| 47100/tcp | signaling (WebSocket) |
| 47100/udp | embedded STUN/TURN |
| 47101/tcp | TURN over TCP (networks that block UDP) |
| 47102/udp | LAN discovery |

### Architecture

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

More: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), protocol: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

### Download

Ready-made builds for every platform are on the **[Releases](https://github.com/sibawal/thelxis/releases/latest)** page:

| Platform | Files |
|---|---|
| Windows | installer `Thelxis-<version>-windows-x64-setup.exe`, archive `Thelxis-<version>-windows-x64.zip` |
| macOS | `Thelxis-<version>-macos-universal.dmg` |
| Linux | `thelxis_<version>_amd64.deb`, `Thelxis-<version>-linux-x64.tar.gz` |
| Android | `Thelxis-<version>-android-<abi>.apk` or `...-universal.apk` |

Builds are not signed with a developer certificate - first-launch instructions (SmartScreen, Gatekeeper, macOS
permissions, the Android accessibility service) are in each release's notes.

### Building from source

You need Flutter 3.47 (Dart 3.13) plus the native toolchain of your target: Visual Studio (C++ desktop workload)
on Windows, Xcode on macOS, `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libx11-dev libxi-dev` on
Linux (Ubuntu 22.04+), JDK 17 and the Android SDK for Android.

```bash
cd app
flutter pub get
flutter analyze && flutter test
flutter run -d macos          # or windows / linux / <android device>
flutter build apk --release   # or: macos | windows | linux
```

Icons: `packaging/icons/generate.sh` (Python 3 + Pillow + numpy) redraws the logo and refreshes the platform
icons. Releases are cut with a tag: see [`packaging/README.md`](packaging/README.md).

### Repository layout

```
app/          Flutter app (Windows, macOS, Linux, Android)
docs/         architecture, protocol, decisions
packaging/    icons, Windows installer (Inno Setup), .deb builder, release notes template
.github/      GitHub Actions: CI and releases
```

### Roadmap

- **v0.1** - serverless P2P, signed handshake, embedded STUN/TURN, UPnP/NAT-PMP, LAN discovery, invite links,
  password / request / trusted-key auth, control, multi-monitor, clipboard text, quality presets, stats, address
  book, releases for all platforms.
- **v0.2** - Windows service / macOS LaunchDaemon for login-screen access, file transfer, chat UI, Wayland input,
  audio, optional decentralized address lookup (DHT, signed records) for dynamic IPs, auto-update.
- **v0.3** - signed fleet policy files, local session recording, 2FA on the host, iOS viewer.
