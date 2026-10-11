#!/usr/bin/env bash
# Sign a macOS .app inside-out (nested frameworks/dylibs/helpers first, the app last).
#
# Usage: sign_app.sh <Thelxis.app> <entitlements.plist>
# Env:   CODESIGN_IDENTITY  identity SHA-1 or name in the keychain; "-" (default) means ad-hoc
#        CODESIGN_KEYCHAIN  keychain file holding that identity (optional)
#
# With a real (even self-signed) certificate the designated requirement becomes
# `identifier "<bundle id>" and certificate leaf = H"<cert hash>"`, which stays the same across
# releases - that is what keeps macOS Screen Recording / Accessibility grants valid after an update.
# An ad-hoc signature has a per-build cdhash requirement, so those grants are lost on every update.
set -euo pipefail

app="${1:?usage: sign_app.sh <app> <entitlements.plist>}"
entitlements="${2:?usage: sign_app.sh <app> <entitlements.plist>}"
identity="${CODESIGN_IDENTITY:--}"

[ -d "$app/Contents" ] || { echo "error: $app is not an app bundle" >&2; exit 1; }
app="$(cd "$app" && pwd)"
[ -f "$entitlements" ] || { echo "error: entitlements file $entitlements not found" >&2; exit 1; }

keychain_args=()
if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
  keychain_args=(--keychain "$CODESIGN_KEYCHAIN")
fi

# No timestamp server: it is a self-signed/ad-hoc build and the network call only adds a failure mode.
sign() {
  codesign --force --sign "$identity" ${keychain_args[@]+"${keychain_args[@]}"} --timestamp=none "$@"
}

exe_name="$(defaults read "$app/Contents/Info" CFBundleExecutable)"
main_exe="$app/Contents/MacOS/$exe_name"

nested="$(mktemp)"
trap 'rm -f "$nested"' EXIT

# Nested bundles (frameworks, plugins, helper apps, XPC services) ...
find "$app/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) -print >> "$nested"
# ... and every loose Mach-O except the main executable (dylibs, helper tools).
while IFS= read -r -d '' f; do
  [ "$f" = "$main_exe" ] && continue
  if file -b "$f" | grep -q 'Mach-O'; then
    printf '%s\n' "$f" >> "$nested"
  fi
done < <(find "$app/Contents" -type f -print0)

# Deepest paths first = inside-out.
count=0
while IFS= read -r path; do
  sign "$path"
  count=$((count + 1))
done < <(awk -F/ '{ print NF "\t" $0 }' "$nested" | sort -rn | cut -f2-)
echo "Signed $count nested items"

sign --entitlements "$entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
echo "--- designated requirement"
dr="$(codesign -dr - "$app" 2>&1 | grep -E '^(# )?designated' || true)"
echo "$dr"
if [ "$identity" != "-" ] && ! printf '%s' "$dr" | grep -q 'certificate leaf'; then
  echo "error: designated requirement is not anchored to the signing certificate" >&2
  exit 1
fi
