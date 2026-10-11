#!/usr/bin/env bash
# Redraw all brand assets and regenerate the platform launcher icons.
# Needs: python3 + Pillow + numpy, and the Flutter SDK on PATH.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 "$root/packaging/icons/make_icons.py"

cd "$root/app"
flutter pub get
dart run flutter_launcher_icons -f flutter_launcher_icons.yaml

# flutter_launcher_icons writes a single-size .ico; replace it with a multi-size one
# (16..256) so Explorer, the taskbar and the installer all get a crisp icon.
python3 "$root/packaging/icons/make_icons.py" --windows-ico
