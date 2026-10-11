#!/usr/bin/env bash
# Import a PKCS#12 code-signing identity into a fresh temporary keychain.
#
# Usage:  import_cert.sh <keychain_path>
# Env:    CERT_P12_BASE64  base64 of the .p12 file
#         CERT_PASSWORD    its password
# stdout: the SHA-1 hash of the imported identity (all other output goes to stderr),
#         so callers can do   identity="$(import_cert.sh "$keychain")".
# Undo with remove_cert.sh <keychain_path> (deletes the keychain and restores the search list).
set -euo pipefail

keychain="${1:?usage: import_cert.sh <keychain_path>}"
: "${CERT_P12_BASE64:?CERT_P12_BASE64 is not set}"
: "${CERT_PASSWORD:?CERT_PASSWORD is not set}"

p12="$(mktemp)"
trap 'rm -f "$p12"' EXIT

# Throw-away password: the keychain only lives for the duration of one CI job.
keychain_password="$(uuidgen)"

security create-keychain -p "$keychain_password" "$keychain" >&2
# Stay unlocked for 6 hours so later steps can sign without a prompt.
security set-keychain-settings -lut 21600 "$keychain" >&2
security unlock-keychain -p "$keychain_password" "$keychain" >&2

printf '%s' "$CERT_P12_BASE64" | base64 --decode > "$p12"
# -T lets codesign use the key without a GUI prompt.
security import "$p12" -f pkcs12 -k "$keychain" -P "$CERT_PASSWORD" -T /usr/bin/codesign >&2
# Newer macOS also needs the partition list, otherwise codesign still prompts.
# (it dumps every key's attributes on stdout, hence the redirect).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null

# codesign only finds an identity whose keychain is on the search list; "--keychain <file>" alone is not enough
# for a self-signed (untrusted) certificate. remove_cert.sh puts the original list back.
existing=()
while IFS= read -r k; do
  existing+=("$k")
done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}

# Not "find-identity -v": a self-signed certificate is not trusted by the system, so -v would hide it.
identity="$(security find-identity -p codesigning "$keychain" | awk '/^ *[0-9]+\)/ { print $2; exit }')"
if [ -z "$identity" ]; then
  echo "error: no code-signing identity found in the imported .p12" >&2
  exit 1
fi
echo "Imported code-signing identity $identity" >&2
printf '%s\n' "$identity"
