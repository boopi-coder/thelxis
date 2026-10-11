# Thelxis {{VERSION}}

**Русский** | [English](#english)

Thelxis — удалённый рабочий стол «компьютер — компьютер» (Windows, macOS, Linux, Android): прямое зашифрованное
соединение, без серверов и без аккаунтов. Ключи шифрования никогда не покидают ваши устройства.

## Скачать

| Платформа | Файл |
|---|---|
| Windows 10/11 x64 | [`Thelxis-{{VERSION}}-windows-x64-setup.exe`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-windows-x64-setup.exe) (установщик), [`Thelxis-{{VERSION}}-windows-x64.zip`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-windows-x64.zip) (без установки) |
| macOS 12+ (Apple Silicon и Intel) | [`Thelxis-{{VERSION}}-macos-universal.dmg`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-macos-universal.dmg) |
| Linux x64 | [`thelxis_{{VERSION}}_amd64.deb`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/thelxis_{{VERSION}}_amd64.deb), [`Thelxis-{{VERSION}}-linux-x64.tar.gz`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-linux-x64.tar.gz) |
| Android 7.0+ | `Thelxis-{{VERSION}}-android-arm64-v8a.apk` (большинство телефонов), `...-armeabi-v7a.apk` (старые 32-битные), `...-x86_64.apk` (эмуляторы, Chromebook), `...-universal.apk` (если не уверены) |

Контрольные суммы всех файлов — в `SHA256SUMS.txt`.

## Установка

Сборки не подписаны сертификатом разработчика, поэтому системы показывают предупреждение при первом запуске.

### Windows
1. Запустите `...-setup.exe`. Если появится окно SmartScreen «Windows защитила ваш компьютер» — нажмите
   **Подробнее -> Выполнить в любом случае**.
2. Установщик добавляет правила брандмауэра для `thelxis.exe` (входящие: TCP 47100-47101, UDP 47100, UDP 47102)
   и при удалении убирает их. Можно отметить «Запускать при старте Windows».
3. Вариант без установки: распакуйте `.zip` и запустите `thelxis.exe` (правила брандмауэра тогда нужно добавить
   вручную или разрешить доступ в появившемся окне Windows).

### macOS
1. Откройте `.dmg` и перетащите **Thelxis** в «Программы».
2. Первый запуск: правый клик по Thelxis -> **Открыть** -> «Открыть». В macOS 15 (Sequoia) и новее после первой
   блокировки откройте **Системные настройки -> Конфиденциальность и безопасность** и нажмите **«Всё равно открыть»**.
   Альтернатива: `xattr -dr com.apple.quarantine /Applications/Thelxis.app`.
3. Выдайте разрешения в **Системные настройки -> Конфиденциальность и безопасность**:
   **Запись экрана** (чтобы показывать свой экран) и **Универсальный доступ** (чтобы управлять мышью и клавиатурой).
   После выдачи разрешений перезапустите приложение. Приложение подписано постоянным сертификатом Thelxis, поэтому
   эти разрешения сохраняются при обновлениях.

### Linux
- `.deb` (Debian, Ubuntu и производные): `sudo apt install ./thelxis_{{VERSION}}_amd64.deb`, затем запустите
  «Thelxis» из меню приложений или командой `thelxis`.
- `.tar.gz`: распакуйте и запустите `./thelxis`. Нужны GTK 3 и библиотеки X11 (`libxtst6`, `libxrandr2`).
- Управление (ввод мыши и клавиатуры) работает в сеансе **X11**. В Wayland экран показать можно, но ввод пока не
  поддерживается.
- Значок в трее: в GNOME нужно расширение AppIndicator (в Ubuntu включено по умолчанию).

### Android
1. Скачайте APK, откройте его и разрешите установку из неизвестных источников для вашего браузера/файлового менеджера.
2. Чтобы **управлять** этим телефоном, включите службу специальных возможностей Thelxis:
   **Настройки -> Специальные возможности -> Установленные приложения -> Thelxis -> Включить**.
3. Показ экрана запрашивает системное разрешение на захват экрана при каждом включении.

## Как устроено соединение

Без серверов-посредников. Приложение пробует по порядку: автообнаружение в локальной сети -> прямой IPv6 ->
подключение к хосту по порту 47100 (авто-проброс UPnP/NAT-PMP или ручной проброс) -> обратное соединение
(управляемый компьютер сам подключается к вам) -> по желанию публичный STUN (по умолчанию выключен).
В каждом приложении встроены свои STUN/TURN, поэтому NAT на другой стороне не мешает.

| Порт | Назначение |
|---|---|
| 47100/tcp | сигнализация (WebSocket) |
| 47100/udp | встроенный STUN/TURN |
| 47101/tcp | TURN поверх TCP (сети, блокирующие UDP) |
| 47102/udp | обнаружение в локальной сети |

Если и у вас, и у собеседника нет ни публичного адреса, ни IPv6 (например, оба за CGNAT), включите опциональный
публичный STUN или используйте VPN-оверлей (Tailscale, ZeroTier, WireGuard).

---

## English

Thelxis is a PC-to-PC remote desktop (Windows, macOS, Linux, Android): a direct, end-to-end encrypted connection
with no servers and no accounts. Encryption keys never leave your devices.

## Download

| Platform | File |
|---|---|
| Windows 10/11 x64 | [`Thelxis-{{VERSION}}-windows-x64-setup.exe`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-windows-x64-setup.exe) (installer), [`Thelxis-{{VERSION}}-windows-x64.zip`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-windows-x64.zip) (portable) |
| macOS 12+ (Apple Silicon and Intel) | [`Thelxis-{{VERSION}}-macos-universal.dmg`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-macos-universal.dmg) |
| Linux x64 | [`thelxis_{{VERSION}}_amd64.deb`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/thelxis_{{VERSION}}_amd64.deb), [`Thelxis-{{VERSION}}-linux-x64.tar.gz`](https://github.com/sibawal/thelxis/releases/download/{{TAG}}/Thelxis-{{VERSION}}-linux-x64.tar.gz) |
| Android 7.0+ | `Thelxis-{{VERSION}}-android-arm64-v8a.apk` (most phones), `...-armeabi-v7a.apk` (older 32-bit), `...-x86_64.apk` (emulators, Chromebooks), `...-universal.apk` (if unsure) |

SHA-256 checksums of every file are in `SHA256SUMS.txt`.

## Install

These builds are not signed with a developer certificate, so your OS warns you on first launch.

### Windows
1. Run `...-setup.exe`. If SmartScreen shows "Windows protected your PC", click **More info -> Run anyway**.
2. The installer adds Windows Firewall rules for `thelxis.exe` (inbound TCP 47100-47101, UDP 47100, UDP 47102) and
   removes them on uninstall. You can tick "Start Thelxis when Windows starts".
3. Portable option: unzip the `.zip` and run `thelxis.exe` (then allow it through the firewall when Windows asks,
   or add the rules yourself).

### macOS
1. Open the `.dmg` and drag **Thelxis** to Applications.
2. First launch: right-click Thelxis -> **Open** -> "Open". On macOS 15 (Sequoia) and later, after the first block
   open **System Settings -> Privacy & Security** and click **Open Anyway**. Alternative:
   `xattr -dr com.apple.quarantine /Applications/Thelxis.app`.
3. Grant permissions in **System Settings -> Privacy & Security**: **Screen Recording** (to share your screen) and
   **Accessibility** (to let a remote person use your mouse and keyboard). Restart the app after granting. The app is
   signed with a stable Thelxis certificate, so these permissions survive updates.

### Linux
- `.deb` (Debian, Ubuntu and derivatives): `sudo apt install ./thelxis_{{VERSION}}_amd64.deb`, then start
  "Thelxis" from the app menu or run `thelxis`.
- `.tar.gz`: extract and run `./thelxis`. Needs GTK 3 and the X11 libraries (`libxtst6`, `libxrandr2`).
- Remote control (mouse and keyboard input) works in an **X11** session. On Wayland the screen can be shared but
  input is not supported yet.
- Tray icon: GNOME needs the AppIndicator extension (enabled by default on Ubuntu).

### Android
1. Download the APK, open it and allow installing from unknown sources for your browser/file manager.
2. To let someone **control** this phone, enable the Thelxis accessibility service:
   **Settings -> Accessibility -> Installed apps -> Thelxis -> turn on**.
3. Sharing the screen asks for the system screen-capture permission each time it starts.

## How connections work

No intermediary servers. The app tries, in order: LAN auto-discovery -> direct IPv6 -> reaching the host on
port 47100 (automatic UPnP/NAT-PMP mapping or a manual port forward) -> reverse connection (the controlled
computer dials out to you) -> optionally a public STUN server (off by default). Every app embeds its own STUN/TURN,
so the other side's NAT does not matter.

| Port | Purpose |
|---|---|
| 47100/tcp | signaling (WebSocket) |
| 47100/udp | embedded STUN/TURN |
| 47101/tcp | TURN over TCP (networks that block UDP) |
| 47102/udp | LAN discovery |

If neither side has a public address or IPv6 (for example both are behind carrier-grade NAT), enable the optional
public STUN toggle or use a VPN overlay (Tailscale, ZeroTier, WireGuard).
