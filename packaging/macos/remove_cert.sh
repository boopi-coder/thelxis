#!/usr/bin/env bash
# Delete the temporary keychain made by import_cert.sh and take it off the keychain search list.
# Safe to run when the keychain does not exist (used from an `if: always()` CI step).
#
# Usage: remove_cert.sh <keychain_path>
set -uo pipefail

keychain="${1:?usage: remove_cert.sh <keychain_path>}"

remaining=()
while IFS= read -r k; do
  if [ "$k" != "$keychain" ]; then
    remaining+=("$k")
  fi
done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')

if [ "${#remaining[@]}" -gt 0 ]; then
  security list-keychains -d user -s "${remaining[@]}" || true
fi
security delete-keychain "$keychain" 2>/dev/null || true
rm -f "$keychain"
echo "Removed temporary keychain $keychain"
