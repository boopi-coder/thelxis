# Packaging and releases

Everything that turns the Flutter app into downloadable files lives here and in `.github/workflows/`.

```
.github/workflows/build.yml    reusable pipeline: analyze/test + Android, Windows, macOS, Linux builds
.github/workflows/ci.yml       push to main / pull requests -> build.yml (dev version, no secrets)
.github/workflows/release.yml  tag v* -> build.yml -> SHA256SUMS.txt -> GitHub Release
packaging/RELEASE_NOTES.md     release description template (RU + EN); {{VERSION}} and {{TAG}} are substituted
packaging/icons/               make_icons.py draws the logo, generate.sh refreshes every platform icon
packaging/linux/               build_deb.sh + the 512 px hicolor icon
packaging/windows/             thelxis.iss, the Inno Setup installer script
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
| `SHA256SUMS.txt` | checksums of all of the above |

- A tag with a pre-release suffix (`v0.2.0-rc.1`) is published as a pre-release. The `.deb` package version
  becomes `0.2.0~rc.1` so it sorts before `0.2.0`.
- The tag must match `vMAJOR.MINOR.PATCH[-suffix]`; anything else fails fast in the `prepare` job.
- Without a tag push: **Actions -> Release -> Run workflow** and type the tag; it is created on the selected commit.
- The Android build number is the workflow run number, so it increases with every build.
- Keep `version:` in `app/pubspec.yaml` roughly in step with the tag (CI overrides name and number at build time).

Every push to `main` and every pull request runs `ci.yml` with version `0.0.0-dev.<run number>`; its artifacts
are kept for 14 days under the run's **Artifacts** section. Changes that only touch `docs/**` or `*.md` skip CI.

## Required secrets

Repository **Settings -> Secrets and variables -> Actions**:

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | base64 of the release keystore (`.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | key password |

`GITHUB_TOKEN` is provided automatically; nothing else is needed. If the four Android secrets are missing, the
build still succeeds but the APKs are signed with the **debug** key and the release run shows a warning. Do not
publish such APKs for real users: phones refuse to update an app whose signing key changed.

Create the keystore once and **back it up** (losing it means users must uninstall to update):

```bash
keytool -genkeypair -v -keystore thelxis-release.jks -alias thelxis \
  -keyalg RSA -keysize 4096 -validity 10000
base64 < thelxis-release.jks | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 --repo sibawal/thelxis
gh secret set ANDROID_KEYSTORE_PASSWORD --repo sibawal/thelxis
gh secret set ANDROID_KEY_ALIAS --repo sibawal/thelxis --body thelxis
gh secret set ANDROID_KEY_PASSWORD --repo sibawal/thelxis
```

At build time the workflow writes `app/android/app/release.jks` and `app/android/key.properties`
(`storePassword`, `keyPassword`, `keyAlias`, `storeFile` as an absolute path); both are git-ignored. The Gradle
config reads `key.properties` when it exists and falls back to the debug key otherwise.

## Platform notes

- **macOS** - the build runs on the free Apple Silicon runner. Flutter release builds are universal by default and
  the job fails unless every Mach-O file in the bundle has both `arm64` and `x86_64`, so Intel Macs are covered.
  The app is only ad-hoc signed (no Developer ID), hence the "Open Anyway" steps in the release notes.
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
