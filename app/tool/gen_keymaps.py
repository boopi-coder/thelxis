#!/usr/bin/env python3
"""Generates the HID -> native key code tables used by the input injectors.

Source of truth: Chromium's ui/events/keycodes/dom/dom_code_data.inc. Every
DOM_CODE row lists, for one physical key, the USB HID usage and the matching
Linux evdev, XKB, Windows scan code and macOS virtual key code:

    DOM_CODE(USB, evdev, XKB, Win, Mac, "Code", ENUM)

Output (Dart const maps keyed by the USB HID usage `page << 16 | id`, exactly
what the `kd`/`ku` input messages carry, PROTOCOL.md section 5.3):

    lib/platform/impl/keymap/hid_to_win_scancode.dart
    lib/platform/impl/keymap/hid_to_mac_vk.dart
    lib/platform/impl/keymap/hid_to_evdev.dart

Usage (from the app/ directory):

    python3 tool/gen_keymaps.py                  # downloads the pinned file
    python3 tool/gen_keymaps.py --input FILE     # use a local copy

The download tracks Chromium `main`; the sha256 of the input is recorded in
the generated headers so a diff after regeneration is always explainable.
Pin CHROMIUM_REV to a commit hash for fully reproducible output.
"""

import argparse
import base64
import hashlib
import os
import re
import sys
import urllib.request

CHROMIUM_REV = "main"
SOURCE_URL = (
    "https://chromium.googlesource.com/chromium/src/+/%s/"
    "ui/events/keycodes/dom/dom_code_data.inc?format=TEXT" % CHROMIUM_REV
)

# DOM_CODE(0x070004, 0x001e, 0x0026, 0x001e, 0x0000, "KeyA", US_A)
ROW_RE = re.compile(
    r"DOM_CODE\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,"
    r"\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,"
    r"\s*(\"[^\"]*\"|NULL)\s*,\s*([A-Z0-9_]+)\s*\)"
)

MAC_NONE = 0xFFFF


def fetch(path):
    if path:
        with open(path, "rb") as f:
            return f.read()
    with urllib.request.urlopen(SOURCE_URL, timeout=60) as resp:
        return base64.b64decode(resp.read())


def strip_comments(text):
    # Rows can span lines; comments never contain string literals we need.
    lines = []
    for line in text.splitlines():
        idx = line.find("//")
        lines.append(line if idx < 0 else line[:idx])
    return "\n".join(lines)


def parse(raw):
    text = strip_comments(raw.decode("utf-8"))
    rows = []
    for m in ROW_RE.finditer(text):
        usb, evdev, xkb, win, mac = (int(m.group(i), 16) for i in range(1, 6))
        name = m.group(6).strip('"') if m.group(6) != "NULL" else m.group(7)
        rows.append({"usb": usb, "evdev": evdev, "win": win, "mac": mac, "name": name})
    if not rows:
        raise SystemExit("no DOM_CODE rows found; format changed?")
    return rows


def header(title, sha):
    return (
        "// GENERATED FILE - DO NOT EDIT.\n"
        "// Generator: tool/gen_keymaps.py\n"
        "// Source:    Chromium ui/events/keycodes/dom/dom_code_data.inc\n"
        "//            (sha256 %s)\n"
        "// %s\n\n" % (sha, title)
    )


def emit_map(name, doc, entries, width):
    out = ["/// %s\n" % doc, "const Map<int, int> %s = {\n" % name]
    for usb, value, label in sorted(entries):
        out.append(
            "  0x%08x: 0x%0*x, // %s\n" % (usb, width, value, label)
        )
    out.append("};\n")
    return "".join(out)


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    print("wrote", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="local dom_code_data.inc instead of downloading")
    ap.add_argument(
        "--out",
        default=os.path.join("lib", "platform", "impl", "keymap"),
        help="output directory (default: lib/platform/impl/keymap)",
    )
    args = ap.parse_args()

    raw = fetch(args.input)
    sha = hashlib.sha256(raw).hexdigest()
    rows = parse(raw)

    win, mac, evdev = [], [], []
    for r in rows:
        if r["usb"] == 0:
            continue
        if r["win"] != 0:
            win.append((r["usb"], r["win"], r["name"]))
        if r["mac"] != MAC_NONE:
            mac.append((r["usb"], r["mac"], r["name"]))
        if r["evdev"] != 0:
            evdev.append((r["usb"], r["evdev"], r["name"]))

    write(
        os.path.join(args.out, "hid_to_win_scancode.dart"),
        header("USB HID usage -> Windows set-1 scan code (0xE0xx = extended key).", sha)
        + "/// Mask of the `0xE0` prefix Chromium puts in the high byte of extended keys.\n"
        "const int winScanExtendedMask = 0xff00;\n"
        "const int winScanExtendedPrefix = 0xe000;\n\n"
        "/// The scan code byte to put in `KEYBDINPUT.wScan`.\n"
        "int winScanCode(int entry) => entry & 0xff;\n\n"
        "/// True when `KEYEVENTF_EXTENDEDKEY` must accompany the scan code.\n"
        "bool winScanIsExtended(int entry) =>\n"
        "    (entry & winScanExtendedMask) == winScanExtendedPrefix;\n\n"
        + emit_map(
            "hidToWinScancode",
            "Keyed by USB HID usage (page << 16 | id).",
            win,
            4,
        ),
    )
    write(
        os.path.join(args.out, "hid_to_mac_vk.dart"),
        header("USB HID usage -> macOS virtual key code (kVK_*).", sha)
        + emit_map(
            "hidToMacVk",
            "Keyed by USB HID usage (page << 16 | id).",
            mac,
            2,
        ),
    )
    write(
        os.path.join(args.out, "hid_to_evdev.dart"),
        header("USB HID usage -> Linux evdev key code (X11 keycode = evdev + 8).", sha)
        + "/// Offset between evdev codes and X11 keycodes.\n"
        "const int evdevToX11Offset = 8;\n\n"
        + emit_map(
            "hidToEvdev",
            "Keyed by USB HID usage (page << 16 | id).",
            evdev,
            4,
        ),
    )
    print("rows: %d win=%d mac=%d evdev=%d" % (len(rows), len(win), len(mac), len(evdev)))


if __name__ == "__main__":
    sys.exit(main())
