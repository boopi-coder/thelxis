#!/usr/bin/env bash
# Build thelxis_<version>_amd64.deb from a Flutter Linux release bundle.
#
# Usage: build_deb.sh <version> <bundle_dir> <application_id> <out_dir>
#   version         e.g. 0.1.0, 0.2.0-rc.1 (a pre-release "-" becomes "~" so it sorts before the final)
#   bundle_dir      app/build/linux/x64/release/bundle
#   application_id  GApplication id from app/linux/CMakeLists.txt (names the .desktop file and its window class)
#   out_dir         where the .deb is written
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <version> <bundle_dir> <application_id> <out_dir>" >&2
  exit 64
fi

version="$1"
bundle="$2"
app_id="$3"
out_dir="$4"
arch="${DEB_ARCH:-amd64}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
icon="$here/thelxis.png"

[ -x "$bundle/thelxis" ] || { echo "error: $bundle/thelxis is missing or not executable" >&2; exit 1; }
[ -f "$icon" ] || { echo "error: icon $icon not found" >&2; exit 1; }

# Debian sorts "0.2.0~rc.1" before "0.2.0", so a pre-release "-" becomes "~". The tilde lives in a variable
# because a literal "~" in a ${var//-/~} replacement is tilde-expanded to $HOME by newer bash versions.
version_re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
if ! [[ "$version" =~ $version_re ]]; then
  echo "error: version '$version' must look like 1.2.3 or 1.2.3-rc.1" >&2
  exit 1
fi
tilde='~'
deb_version="${version//-/$tilde}"
deb_version_re='^[0-9]+\.[0-9]+\.[0-9]+(~[0-9A-Za-z.]+)?$'
if ! [[ "$deb_version" =~ $deb_version_re ]]; then
  echo "error: computed Debian version '$deb_version' is invalid" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/thelxis"

install -d -m 0755 \
  "$pkg/DEBIAN" \
  "$pkg/opt/thelxis" \
  "$pkg/usr/bin" \
  "$pkg/usr/share/applications" \
  "$pkg/usr/share/icons/hicolor/512x512/apps"

# The Flutter bundle is relocatable (RPATH $ORIGIN/lib), so it lives in /opt as one unit.
cp -a "$bundle/." "$pkg/opt/thelxis/"
chmod -R u+rwX,go+rX,go-w "$pkg/opt/thelxis"
ln -s /opt/thelxis/thelxis "$pkg/usr/bin/thelxis"

install -m 0644 "$icon" "$pkg/usr/share/icons/hicolor/512x512/apps/thelxis.png"

cat > "$pkg/usr/share/applications/$app_id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Thelxis
GenericName=Remote Desktop
GenericName[ru]=Удалённый рабочий стол
Comment=Direct encrypted remote desktop, no servers
Comment[ru]=Прямое зашифрованное удалённое управление без серверов
Exec=thelxis
Icon=thelxis
Terminal=false
Categories=Network;RemoteAccess;
Keywords=remote;desktop;screen;control;rdp;vnc;
StartupNotify=true
StartupWMClass=$app_id
DESKTOP
chmod 0644 "$pkg/usr/share/applications/$app_id.desktop"

installed_kb="$(du -sk "$pkg" | cut -f1)"

# Runtime libraries: GTK for the window, X11 family for capture/input injection (XTest) and the tray,
# PulseAudio for audio capture. The tray icon is a D-Bus StatusNotifierItem (no appindicator library);
# GNOME needs its AppIndicator extension (enabled by default on Ubuntu) to display it.
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: thelxis
Version: $deb_version
Section: net
Priority: optional
Architecture: $arch
Installed-Size: $installed_kb
Maintainer: Thelxis <noreply@users.noreply.github.com>
Homepage: https://github.com/sibawal/thelxis
Depends: libc6, libgtk-3-0, libglib2.0-0, libx11-6, libxext6, libxi6, libxtst6, libxrandr2, libxcomposite1, libxdamage1, libxfixes3, libxrender1, libdrm2, libgbm1, libpulse0, libasound2
Description: Direct encrypted remote desktop
 Thelxis lets you view and control another computer or phone over a direct,
 end-to-end encrypted peer-to-peer connection. There are no servers and no
 accounts: encryption keys never leave your devices.
 .
 Screen control requires an X11 session (Wayland input is not supported yet).
CONTROL
chmod 0644 "$pkg/DEBIAN/control"

mkdir -p "$out_dir"
# File name keeps the release version verbatim ("~" is mangled by some download hosts).
out="$out_dir/thelxis_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$pkg" "$out"
echo "Built $out"
dpkg-deb --info "$out"
