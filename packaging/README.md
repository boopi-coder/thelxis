# Packaging and releases

Everything that turns the Flutter app into downloadable files lives here and in `.github/workflows/`.

```
.github/workflows/build.yml    reusable pipeline: analyze/test + Android, Windows, macOS, Linux builds
.github/workflows/ci.yml       push to main / pull requests -> build.yml (dev version, no secrets)
.github/workflows/release.yml  tag v* -> build.yml -> signed update.json -> SHA256SUMS.txt -> GitHub Release
packaging/RELEASE_NOTES.md     release description template (RU + EN); {{VERSION}} and {{TAG}} are substituted
packaging/icons/               make_icons.py draws the logo, generate.sh refreshes every platform icon
packaging/linux/               build_deb.sh + the 512 px hicolor icon
packaging/windows/             thelxis.iss, the Inno Setup installer script
packaging/macos/               import_cert.sh / sign_app.sh / remove_cert.sh: code signing with the stable certificate
packaging/sign_update.py       builds, signs and verifies update.json (Ed25519)
```

## Cutting a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

`release.yml` builds everything with version `0.1.0`, then publishes a GitHub Release `v0.1.0` with:

| File | Platform |
|---|---|
| `Thelxis-<ver>-windows-x64-setup.exe`, `Thelxis-<ver>-windows-x64.zip` | Windows |
| `Thelxis-<ver>-macos-universal.dmg` | macOS (arm64 + x86_64) |
| `thelxis_<ver>_amd64.deb`, `Thelxis-<ver>-linux-x64.tar.gz` | Linux |
| `Thelxis-<ver>-android-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk` | Android |
| `update.json`, `update.json.sig` | signed update manifest for the in-app updater (stable releases only) |
| `SHA256SUMS.txt` | checksums of everything above |

(The release also contains `Thelxis-<ver>-windows-x64.zip`, the portable Windows build.)

- A tag with a pre-release suffix (`v0.2.0-rc.1`) is published as a pre-release. The `.deb` package version
  becomes `0.2.0~rc.1` so it sorts before `0.2.0`.
- The tag must match `vMAJOR.MINOR.PATCH[-suffix]`; anything else fails fast in the `prepare` job.
- Without a tag push: **Actions -> Release -> Run workflow** and type the tag; it is created on the selected commit.
- The Android build number is the workflow run number, so it increases with every build.
- Keep `version:` in `app/pubspec.yaml` roughly in step with the tag (CI overrides name and number at build time).

Every push to `main` and every pull request runs `ci.yml` with version `0.0.0-dev.<run number>`; its artifacts
are kept for 14 days under the run's **Artifacts** section. Changes that only touch `docs/**` or `*.md` skip CI.

## Over-the-air updates

The app polls `https://github.com/boopi-coder/thelxis/releases/latest/download/update.json` (+ `.sig`), see
`docs/PROTOCOL.md` section 10. In `release.yml`, for stable tags only (a tag containing `-` is a pre-release and gets
no manifest; `releases/latest` ignores pre-releases anyway), the `publish` job:

1. runs `packaging/sign_update.py manifest`: `update.json` with `v`, `version`, `published`, `notes_url` and one
   `{name,url,size,sha256}` entry per asset key (fixed key order, 2-space indent, UTF-8, trailing newline);
2. signs the exact bytes with Ed25519 (`UPDATE_SIGNING_KEY`) into `update.json.sig` = base64url, no padding;
3. verifies the signature against the public key `CCI7L8D_i2lGhmSZvtjKdTP76EbtWRipgrIw3_Cdgvk` and re-checks
   every asset's name, size and SHA-256 against the files; any mismatch fails the release before anything is
   published (it also fails if `app/lib/update/update_trust.dart` pins a different key);
4. uploads everything as a **draft** release and publishes it only when all assets are present;
5. fetches the live `releases/latest/download/update.json` and verifies it again (informational).

| Asset key | File |
|---|---|
| `windows-x64` | `Thelxis-<ver>-windows-x64-setup.exe` |
| `macos-universal` | `Thelxis-<ver>-macos-universal.dmg` |
| `linux-x64-deb` | `thelxis_<ver>_amd64.deb` |
| `linux-x64-tar` | `Thelxis-<ver>-linux-x64.tar.gz` |
| `android-arm64-v8a`, `android-armeabi-v7a`, `android-x86_64`, `android-universal` | `Thelxis-<ver>-android-<abi>.apk` |

The Windows installer supports a silent self-update:
`Thelxis-<ver>-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH`. `/RELAUNCH` makes it start
`thelxis.exe --updated` as the logged-in user when the install finishes. Setup waits while the app's single-instance
mutex (`Local\io.thelxis.app.single-instance`) exists, so the updater must exit the app right after starting Setup.

## Required secrets

Repository **Settings -> Secrets and variables -> Actions**:

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | base64 of the release keystore (`.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | key password |
| `MACOS_CERT_P12_BASE64` | base64 of the stable self-signed "Thelxis Self-Signed Code Signing" identity (`.p12`, legacy PKCS#12 encryption so macOS `security import` accepts it) |
| `MACOS_CERT_PASSWORD` | password of that `.p12` |
| `UPDATE_SIGNING_KEY` | base64 of the raw 32-byte Ed25519 seed that signs `update.json` |

`GITHUB_TOKEN` is provided automatically. `ci.yml` also passes the secrets on (GitHub withholds them from fork pull
requests), so CI builds are signed like releases; `release.yml` fails a stable release if `UPDATE_SIGNING_KEY` is
missing.

- Without the Android secrets the build still succeeds but the APKs are signed with the **debug** key and the
  release run shows a warning. Do not publish such APKs: phones refuse to update an app whose signing key changed.
- Without the macOS secrets the app is only ad-hoc signed (warning on release runs). Its signature changes with every
  build, so macOS forgets the Screen Recording and Accessibility grants after each update.
- Never lose `UPDATE_SIGNING_KEY` or the keystore: apps already installed trust only that key / signature.

Create the Android keystore once and **back it up** (losing it means users must uninstall to update):

```bash
keytool -genkeypair -v -keystore thelxis-release.jks -alias thelxis \
  -keyalg RSA -keysize 4096 -validity 10000
base64 < thelxis-release.jks | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 --repo boopi-coder/thelxis
gh secret set ANDROID_KEYSTORE_PASSWORD --repo boopi-coder/thelxis
gh secret set ANDROID_KEY_ALIAS --repo boopi-coder/thelxis --body thelxis
gh secret set ANDROID_KEY_PASSWORD --repo boopi-coder/thelxis
```

At build time the workflow writes `app/android/app/release.jks` and `app/android/key.properties`
(`storePassword`, `keyPassword`, `keyAlias`, `storeFile` as an absolute path); both are git-ignored. The Gradle
config reads `key.properties` when it exists and falls back to the debug key otherwise.

## Platform notes

- **macOS** - the build runs on the free Apple Silicon runner. Flutter release builds are universal by default and
  the job fails unless every Mach-O file in the bundle has both `arm64` and `x86_64`, so Intel Macs are covered.
  The app is signed with the stable self-signed certificate (`packaging/macos/`: temporary keychain, inside-out
  `codesign` of frameworks/dylibs then the app with `app/macos/Runner/Release.entitlements`, no hardened runtime;
  the keychain is deleted in an `always()` step). Its designated requirement is
  `identifier "<bundle id>" and certificate leaf = H"<cert hash>"`, identical for every release, so privacy grants
  survive updates. There is still no Developer ID/notarization, hence the "Open Anyway" steps in the release notes.
- **Windows** - the installer (Inno Setup 6, preinstalled or installed through Chocolatey) is per-machine, adds
  inbound firewall rules for `thelxis.exe` (TCP 47100-47101, UDP 47100, UDP 47102) and removes them on uninstall.
  The zip and installer bundle the VC++ runtime DLLs, so no redistributable is required. To build the installer by
  hand after `flutter build windows`, run `ISCC packaging\windows\thelxis.iss`.
- **Linux** - built on Ubuntu 22.04 so the binaries run on any distro with an equal or newer glibc. `.deb` installs to
  `/opt/thelxis` with a `/usr/bin/thelxis` link, a desktop entry and a hicolor icon. The tray icon is a D-Bus
  StatusNotifierItem; GNOME needs the AppIndicator extension to show it. No firewall changes are made.
- **Android** - split-per-ABI APKs plus one universal APK; JDK 17 (required by AGP 9 / Gradle 9).

## Icons

`packaging/icons/generate.sh` redraws the logo (`make_icons.py`, needs Python 3 with Pillow and numpy), then runs
`flutter_launcher_icons` (config: `app/flutter_launcher_icons.yaml`) to refresh Android, macOS and Windows icons.
The generated files are committed, so CI does not need Python. Output:

| File | Use |
|---|---|
| `app/assets/icon/app_icon.png` | master 1024 px icon (Android legacy, Windows, README) |
| `app/assets/icon/app_icon_macos.png` | same tile with Apple-style margin and shadow (macOS) |
| `app/assets/icon/app_icon_foreground.png` | Android adaptive foreground (inside the 66% safe zone) |
| `app/assets/icon/app_icon_monochrome.png` | Android 13 themed icon |
| `app/assets/icon/tray.png`, `tray.ico` | tray icon, white on transparent (Windows/Linux) |
| `app/assets/icon/tray_template.png` | macOS menu bar template image (black + alpha) |
| `app/assets/icon/logo.svg` | vector logo |
| `packaging/linux/thelxis.png` | 512 px icon for the `.deb` |
