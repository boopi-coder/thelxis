#!/usr/bin/env python3
"""Build, sign and verify the over-the-air update manifest (docs/PROTOCOL.md section 10).

  manifest  write dist/update.json from the release files in dist/
  sign      sign the exact bytes of update.json with the Ed25519 seed in $UPDATE_SIGNING_KEY
  verify    check update.json.sig against the public key pinned in the app, then cross-check
            the manifest against the real files

update.json.sig is base64url (no padding) of the 64-byte Ed25519 signature over the exact bytes of
update.json. The private key is a base64 (standard or URL-safe) encoding of the raw 32-byte seed and is
only ever read from the environment. Requires the `cryptography` package.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

MANIFEST_VERSION = 1

# Manifest asset key -> release file name. These names are a contract with the updater and with
# .github/workflows/build.yml; change them in all three places together.
ASSETS = {
    "windows-x64": "Thelxis-{v}-windows-x64-setup.exe",
    "macos-universal": "Thelxis-{v}-macos-universal.dmg",
    "linux-x64-deb": "thelxis_{v}_amd64.deb",
    "linux-x64-tar": "Thelxis-{v}-linux-x64.tar.gz",
    "android-arm64-v8a": "Thelxis-{v}-android-arm64-v8a.apk",
    "android-armeabi-v7a": "Thelxis-{v}-android-armeabi-v7a.apk",
    "android-x86_64": "Thelxis-{v}-android-x86_64.apk",
    "android-universal": "Thelxis-{v}-android-universal.apk",
}

STABLE_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
DART_KEY = re.compile(r"""publicKey\s*=\s*['"]([A-Za-z0-9_-]+)['"]""")


class Failure(Exception):
    pass


def b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def b64url_decode(text: str) -> bytes:
    text = "".join(text.split())
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def public_key_from_args(args: argparse.Namespace) -> str:
    if args.public_key:
        return args.public_key.strip()
    if args.public_key_from:
        match = DART_KEY.search(Path(args.public_key_from).read_text(encoding="utf-8"))
        if not match:
            raise Failure(f"no publicKey constant found in {args.public_key_from}")
        return match.group(1)
    raise Failure("give --public-key or --public-key-from")


def load_public_key(text: str) -> Ed25519PublicKey:
    raw = b64url_decode(text)
    if len(raw) != 32:
        raise Failure(f"public key must be 32 bytes, got {len(raw)}")
    return Ed25519PublicKey.from_public_bytes(raw)


def raw_public_bytes(key: Ed25519PublicKey) -> bytes:
    return key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


# ------------------------------------------------------------------ manifest
def cmd_manifest(args: argparse.Namespace) -> None:
    version = args.version
    if not STABLE_VERSION.match(version):
        raise Failure(f"'{version}' is not a stable x.y.z version (pre-releases get no manifest)")
    dist = Path(args.dist)
    base = f"https://github.com/{args.repo}/releases/download/{args.tag}"

    assets = {}
    for key, template in ASSETS.items():
        name = template.format(v=version)
        path = dist / name
        if not path.is_file():
            raise Failure(f"release file missing for '{key}': {path}")
        assets[key] = {
            "name": name,
            "url": f"{base}/{name}",
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        }

    published = args.published or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {
        "v": MANIFEST_VERSION,
        "version": version,
        "published": published,
        "notes_url": f"https://github.com/{args.repo}/releases/tag/{args.tag}",
        "assets": assets,
    }
    # Fixed key order, 2-space indent, UTF-8, trailing newline: the signature covers these exact bytes.
    data = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    Path(args.out).write_bytes(data)
    print(f"wrote {args.out} ({len(data)} bytes, {len(assets)} assets)")


# ---------------------------------------------------------------------- sign
def load_seed() -> Ed25519PrivateKey:
    text = "".join(os.environ.get("UPDATE_SIGNING_KEY", "").split())
    if not text:
        raise Failure("UPDATE_SIGNING_KEY is not set")
    try:
        raw = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))  # accepts standard and URL-safe alphabets
    except ValueError as exc:
        raise Failure("UPDATE_SIGNING_KEY is not valid base64") from exc
    if len(raw) != 32:
        raise Failure(f"UPDATE_SIGNING_KEY must decode to a 32-byte Ed25519 seed, got {len(raw)} bytes")
    return Ed25519PrivateKey.from_private_bytes(raw)


def cmd_sign(args: argparse.Namespace) -> None:
    private = load_seed()
    if args.public_key or args.public_key_from:
        expected = b64url_encode(raw_public_bytes(load_public_key(public_key_from_args(args))))
        actual = b64url_encode(raw_public_bytes(private.public_key()))
        if expected != actual:
            raise Failure(
                "UPDATE_SIGNING_KEY does not belong to the public key pinned in the app "
                f"(secret derives {actual}, app trusts {expected})")
    data = Path(args.manifest).read_bytes()
    signature = private.sign(data)
    Path(args.out).write_text(b64url_encode(signature) + "\n", encoding="ascii")
    print(f"wrote {args.out} (signature over {len(data)} bytes)")


# -------------------------------------------------------------------- verify
def cmd_verify(args: argparse.Namespace) -> None:
    public = load_public_key(public_key_from_args(args))
    data = Path(args.manifest).read_bytes()
    try:
        signature = b64url_decode(Path(args.sig).read_text(encoding="ascii"))
        public.verify(signature, data)
    except (InvalidSignature, ValueError) as exc:
        raise Failure("update.json signature does NOT verify against the pinned public key") from exc
    print("signature OK")

    manifest = json.loads(data.decode("utf-8"))
    if manifest.get("v") != MANIFEST_VERSION:
        raise Failure(f"unexpected manifest version {manifest.get('v')!r}")
    if args.version and manifest.get("version") != args.version:
        raise Failure(f"manifest version {manifest.get('version')!r} != release version {args.version!r}")
    version = manifest["version"]
    assets = manifest.get("assets", {})
    if set(assets) != set(ASSETS):
        raise Failure(f"asset keys differ: {sorted(set(assets) ^ set(ASSETS))}")

    for key, template in ASSETS.items():
        entry = assets[key]
        name = template.format(v=version)
        if entry.get("name") != name:
            raise Failure(f"{key}: name {entry.get('name')!r} != {name!r}")
        if not entry.get("url", "").endswith("/" + name) or not entry["url"].startswith("https://"):
            raise Failure(f"{key}: bad url {entry.get('url')!r}")
        if args.dist:
            path = Path(args.dist) / name
            if not path.is_file():
                raise Failure(f"{key}: {path} not found")
            if path.stat().st_size != entry["size"]:
                raise Failure(f"{key}: size mismatch for {name}")
            if sha256_file(path) != entry["sha256"]:
                raise Failure(f"{key}: sha256 mismatch for {name}")
    print(f"manifest OK: version {version}, {len(assets)} assets"
          + (" match the files in " + args.dist if args.dist else ""))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def add_key_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--public-key", help="Ed25519 public key, raw 32 bytes as base64url")
        p.add_argument("--public-key-from", metavar="DART_FILE",
                       help="read the key from app/lib/update/update_trust.dart")

    p = sub.add_parser("manifest")
    p.add_argument("--version", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--dist", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--published", help="ISO-8601 UTC timestamp (default: now)")
    p.set_defaults(fn=cmd_manifest)

    p = sub.add_parser("sign")
    p.add_argument("--manifest", required=True)
    p.add_argument("--out", required=True)
    add_key_args(p)
    p.set_defaults(fn=cmd_sign)

    p = sub.add_parser("verify")
    p.add_argument("--manifest", required=True)
    p.add_argument("--sig", required=True)
    p.add_argument("--dist", help="also check name/size/sha256 of every asset against this directory")
    p.add_argument("--version", help="require this exact version in the manifest")
    add_key_args(p)
    p.set_defaults(fn=cmd_verify)

    args = parser.parse_args(argv)
    try:
        args.fn(args)
    except Failure as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
