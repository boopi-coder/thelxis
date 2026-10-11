#!/usr/bin/env python3
"""Generate every Thelxis raster/vector brand asset from one parametric drawing.

The logo is a hypnotic Archimedean spiral on a violet -> indigo rounded tile.
All geometry is expressed as a fraction of the canvas, so any output size is
drawn natively (and anti-aliased by supersampling) instead of being scaled.

Requires: Pillow, numpy.   Usage: python3 packaging/icons/make_icons.py [--windows-ico]

  --windows-ico   only (re)write app/windows/runner/resources/app_icon.ico as a
                  multi-size icon (flutter_launcher_icons writes a single size
                  and must run first; see generate.sh).
"""
from __future__ import annotations

import math
import struct
import sys
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
ICON_DIR = ROOT / "app" / "assets" / "icon"
LINUX_PNG = ROOT / "packaging" / "linux" / "thelxis.png"
WINDOWS_ICO = ROOT / "app" / "windows" / "runner" / "resources" / "app_icon.ico"

VIOLET = (0x6C, 0x4C, 0xF5)   # #6C4CF5 - brand seed colour
INDIGO = (0x2B, 0x1B, 0x7A)   # #2B1B7A
GLOW = (0xA8, 0x95, 0xFF)     # lavender halo around the spiral
INNER_GLOW = (0x9A, 0x85, 0xFF)
SPIRAL_TOP = (0xFF, 0xFF, 0xFF)
SPIRAL_BOTTOM = (0xDA, 0xCF, 0xFF)  # very light lavender

TILE_RADIUS = 0.2237   # fraction of the tile edge (Apple-style continuous corner)
ANDROID_SAFE = 0.66    # adaptive icons: only the inner 66% is guaranteed visible


# --------------------------------------------------------------------------
# Spiral geometry
# --------------------------------------------------------------------------
class Spiral:
    """Archimedean spiral r = r0 + (R - r0) * u with a slowly widening stroke.

    `fit()` re-centres the drawing on its bounding box and, if needed, scales it so
    that no pixel leaves a circle of `limit` canvas-fractions radius around the
    canvas centre (the Android adaptive-icon safe zone is such a circle).
    """

    def __init__(self, extent: float, turns: float, w_out: float, w_in: float,
                 end_deg: float = -20.0, core: float = 0.35):
        self.extent = extent          # outermost reach from the core, incl. stroke
        self.turns = turns
        self.w_out = w_out
        self.w_in = w_in
        # the outer tail always ends at the same angle, whatever the turn count
        self.start = math.radians(end_deg - 360.0 * turns)
        self.core = core
        self.ox = 0.0                 # offset applied after centring
        self.oy = 0.0

    @property
    def r_out(self) -> float:
        return self.extent - self.w_out / 2.0

    @property
    def r_in(self) -> float:
        return self.w_in * self.core  # starts inside the cap -> a solid dot at the core

    def samples(self, per_unit: float):
        """Yield (x, y, half_width) relative to the canvas centre, fractions of canvas."""
        theta_max = 2.0 * math.pi * self.turns
        length = 0.5 * theta_max * (self.r_in + self.r_out)   # ~ arc length
        n = max(400, int(length * per_unit))
        for i in range(n + 1):
            u = i / n
            theta = self.start + theta_max * u
            r = self.r_in + (self.r_out - self.r_in) * u
            w = self.w_in + (self.w_out - self.w_in) * math.sqrt(u)
            yield self.ox + r * math.cos(theta), self.oy + r * math.sin(theta), w / 2.0

    def fit(self, limit: float) -> "Spiral":
        self.ox = self.oy = 0.0
        pts = list(self.samples(per_unit=200))
        x0 = min(x - h for x, _, h in pts)
        x1 = max(x + h for x, _, h in pts)
        y0 = min(y - h for _, y, h in pts)
        y1 = max(y + h for _, y, h in pts)
        self.ox, self.oy = -(x0 + x1) / 2.0, -(y0 + y1) / 2.0
        reach = max(math.hypot(x, y) + h for x, y, h in self.samples(per_unit=200))
        if reach > limit:
            k = limit / reach
            self.extent *= k
            self.w_out *= k
            self.w_in *= k
            self.ox *= k
            self.oy *= k
        return self


def app_spiral(size: int, scale: float = 1.0, limit: float = 0.365) -> Spiral:
    """Spiral used on the app icon; fewer, bolder turns for tiny sizes so it stays legible.

    `limit` is the radius (canvas fraction) of the circle the drawing must stay in;
    `scale` shrinks everything for icons drawn with a transparent margin.
    Stroke width is ~55% of the arm pitch, i.e. arms are slightly thicker than gaps.
    """
    ext = 0.40 * scale
    if size <= 32:
        turns, core, w_in = 1.75, 1.0, 0.075
    elif size <= 64:
        turns, core, w_in = 2.25, 1.0, 0.055
    elif size <= 128:
        turns, core, w_in = 2.6, 1.0, 0.035
    else:
        turns, core, w_in = 3.0, 1.2, 0.018
    w_out = 0.55 * 0.31 / turns
    return Spiral(ext, turns, w_out * scale, w_in * scale, core=core).fit(limit * scale)


def tray_spiral(size: int) -> Spiral:
    """Bold single-colour spiral for menu bar / system tray sizes."""
    if size <= 24:
        sp = Spiral(0.47, 1.75, 0.150, 0.110)
    else:
        sp = Spiral(0.47, 2.25, 0.125, 0.090)
    return sp.fit(0.485)


# --------------------------------------------------------------------------
# Rasterising helpers
# --------------------------------------------------------------------------
def _supersample(size: int) -> int:
    if size <= 32:
        return 16
    if size <= 128:
        return 8
    return 4


def spiral_mask(size: int, spiral: Spiral) -> Image.Image:
    """Anti-aliased 'L' mask (size x size) of the spiral stroke, centred."""
    ss = _supersample(size)
    half = int(math.ceil(spiral.extent * size)) + 3
    side = half * 2
    big = Image.new("L", (side * ss, side * ss), 0)
    draw = ImageDraw.Draw(big)
    c = side * ss / 2.0
    k = size * ss
    for x, y, hw in spiral.samples(per_unit=k / 1.4):
        cx, cy, rr = c + x * k, c + y * k, hw * k
        draw.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=255)
    small = big.resize((side, side), Image.BOX)
    out = Image.new("L", (size, size), 0)
    out.paste(small, (size // 2 - half, size // 2 - half))
    return out


def rounded_mask(size: int, inset: float) -> Image.Image:
    """Anti-aliased rounded-square mask; `inset` is the margin as a canvas fraction."""
    ss = 4 if size >= 256 else 8
    big = size * ss
    m = inset * big
    edge = big - 2 * m
    r = TILE_RADIUS * edge
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle((m, m, big - m - 1, big - m - 1), radius=r, fill=255)
    return mask.resize((size, size), Image.BOX)


def gradient(size: int, c1, c2, diagonal: bool = True) -> Image.Image:
    """RGB gradient c1 (top-left) -> c2 (bottom-right)."""
    ax = np.linspace(0.0, 1.0, size, dtype=np.float32)
    t = (ax[None, :] + ax[:, None]) / 2.0 if diagonal else np.repeat(ax[:, None], size, axis=1)
    t = t[..., None]
    arr = np.asarray(c1, np.float32) * (1 - t) + np.asarray(c2, np.float32) * t
    return Image.fromarray(np.clip(arr + 0.5, 0, 255).astype(np.uint8))


def radial_alpha(size: int, cx: float, cy: float, radius: float, peak: float) -> Image.Image:
    """'L' mask: `peak` (0..1) at the centre falling smoothly to 0 at `radius` (fractions)."""
    ax = np.linspace(0.0, 1.0, size, dtype=np.float32)
    d = np.sqrt((ax[None, :] - cx) ** 2 + (ax[:, None] - cy) ** 2) / radius
    f = np.clip(1.0 - d, 0.0, 1.0)
    f = f * f * (3 - 2 * f)  # smoothstep
    return Image.fromarray((f * peak * 255 + 0.5).astype(np.uint8))


def solid(size: int, rgb, alpha_mask: Image.Image, opacity: float = 1.0) -> Image.Image:
    layer = Image.new("RGBA", (size, size), rgb + (0,))
    a = alpha_mask if opacity >= 1.0 else alpha_mask.point(lambda v: int(v * opacity))
    layer.putalpha(a)
    return layer


def blur(mask: Image.Image, radius_px: float) -> Image.Image:
    return mask.filter(ImageFilter.GaussianBlur(radius_px))


def shift(mask: Image.Image, dy: int) -> Image.Image:
    out = Image.new("L", mask.size, 0)
    out.paste(mask, (0, dy))
    return out


def spiral_layers(size: int, spiral: Spiral, with_shadow: bool = True) -> Image.Image:
    """Glow + soft shadow + light spiral on a transparent canvas."""
    mask = spiral_mask(size, spiral)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    unit = size * (spiral.extent / 0.328)   # glow radii follow the drawn spiral size
    # wide halo, then tighter glow: the "enchantment" aura
    canvas = Image.alpha_composite(canvas, solid(size, GLOW, blur(mask, 0.075 * unit), 0.55))
    canvas = Image.alpha_composite(canvas, solid(size, GLOW, blur(mask, 0.028 * unit), 0.75))
    if with_shadow:
        sh = blur(shift(mask, int(0.010 * unit)), 0.012 * unit)
        canvas = Image.alpha_composite(canvas, solid(size, INDIGO, sh, 0.45))
    fill = gradient(size, SPIRAL_TOP, SPIRAL_BOTTOM)
    fill.putalpha(mask)
    return Image.alpha_composite(canvas, fill.convert("RGBA"))


def tile(size: int, inset: float = 0.0, shadow: bool = False) -> Image.Image:
    """Gradient rounded square with a soft inner glow; transparent outside."""
    mask = rounded_mask(size, inset)
    edge = 1.0 - 2 * inset
    base = gradient(size, VIOLET, INDIGO)
    img = base.convert("RGBA")
    # centre glow behind the spiral
    img = Image.alpha_composite(
        img, solid(size, INNER_GLOW, radial_alpha(size, 0.5, 0.47, 0.62 * edge, 0.50)))
    # faint top-edge sheen for depth
    ax = np.linspace(0.0, 1.0, size, dtype=np.float32)
    sheen = np.clip(1.0 - (ax[:, None] - inset) / (0.30 * edge), 0, 1) ** 2 * 0.10
    sheen = np.repeat(sheen, size, axis=1)
    img = Image.alpha_composite(
        img, solid(size, (255, 255, 255), Image.fromarray((sheen * 255).astype(np.uint8))))
    img.putalpha(mask)
    if shadow:
        sh = blur(shift(mask, int(0.014 * size)), 0.018 * size)
        under = solid(size, (0, 0, 0), sh, 0.38)
        img = Image.alpha_composite(under, img)
    return img


def app_icon(size: int, inset: float = 0.0, shadow: bool = False) -> Image.Image:
    scale = 1.0 - 2 * inset
    img = tile(size, inset, shadow)
    return Image.alpha_composite(img, spiral_layers(size, app_spiral(size, scale)))


def foreground(size: int) -> Image.Image:
    """Adaptive-icon foreground: spiral only, inside the 66% safe zone."""
    sp = app_spiral(size, limit=ANDROID_SAFE / 2)
    return spiral_layers(size, sp, with_shadow=False)


def monochrome(size: int) -> Image.Image:
    """Android 13 themed icon: only alpha matters."""
    return solid(size, (0, 0, 0), spiral_mask(size, app_spiral(size, limit=ANDROID_SAFE / 2)))


def tray(size: int, rgb) -> Image.Image:
    return solid(size, rgb, spiral_mask(size, tray_spiral(size)))


# --------------------------------------------------------------------------
# ICO writer: BMP (DIB) frames below 256 for maximum rc.exe/Inno compatibility,
# PNG for 256.
# --------------------------------------------------------------------------
def _dib(img: Image.Image) -> bytes:
    w, h = img.size
    bgra = np.asarray(img.convert("RGBA"), np.uint8)[::-1, :, [2, 1, 0, 3]]
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    mask_row = ((w + 31) // 32) * 4
    return header + bgra.tobytes() + b"\x00" * (mask_row * h)


def write_ico(path: Path, frames: list[Image.Image]) -> None:
    blobs = []
    for im in frames:
        if im.width >= 256:
            buf = BytesIO()
            im.save(buf, "PNG", optimize=True)
            blobs.append(buf.getvalue())
        else:
            blobs.append(_dib(im))
    out = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    offset = 6 + 16 * len(frames)
    for im, blob in zip(frames, blobs):
        w = 0 if im.width >= 256 else im.width
        h = 0 if im.height >= 256 else im.height
        out += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for blob in blobs:
        out += blob
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))


# --------------------------------------------------------------------------
# SVG logo (outline polygon of the variable-width stroke)
# --------------------------------------------------------------------------
def logo_svg() -> str:
    sp = app_spiral(1024)
    pts = list(sp.samples(per_unit=260))
    left, right = [], []
    for i, (x, y, hw) in enumerate(pts):
        x2, y2, _ = pts[min(i + 1, len(pts) - 1)]
        x1, y1, _ = pts[max(i - 1, 0)]
        dx, dy = x2 - x1, y2 - y1
        n = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / n, dx / n
        left.append((x + nx * hw, y + ny * hw))
        right.append((x - nx * hw, y - ny * hw))
    # round cap at the outer end
    x, y, hw = pts[-1]
    x1, y1, _ = pts[-2]
    ang = math.atan2(y - y1, x - x1)
    cap = [(x + hw * math.cos(ang + a), y + hw * math.sin(ang + a))
           for a in np.linspace(math.pi / 2, -math.pi / 2, 14)]
    ring = left + cap + right[::-1]
    d = "M" + " L".join(f"{512 + px * 1024:.1f} {512 + py * 1024:.1f}" for px, py in ring) + "Z"
    r = TILE_RADIUS * 1024
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#6C4CF5"/><stop offset="1" stop-color="#2B1B7A"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.47" r="0.62">
      <stop offset="0" stop-color="#9A85FF" stop-opacity="0.5"/><stop offset="1" stop-color="#9A85FF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="fg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#DACFFF"/>
    </linearGradient>
    <filter id="halo" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="28"/></filter>
  </defs>
  <rect width="1024" height="1024" rx="{r:.0f}" fill="url(#bg)"/>
  <rect width="1024" height="1024" rx="{r:.0f}" fill="url(#glow)"/>
  <path d="{d}" fill="#A895FF" opacity="0.7" filter="url(#halo)"/>
  <path d="{d}" fill="url(#fg)"/>
</svg>
"""


# --------------------------------------------------------------------------
def save_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"  wrote {path.relative_to(ROOT)}  {img.size[0]}x{img.size[1]}")


def windows_ico() -> None:
    sizes = (16, 24, 32, 48, 64, 128, 256)
    write_ico(WINDOWS_ICO, [app_icon(s) for s in sizes])
    print(f"  wrote {WINDOWS_ICO.relative_to(ROOT)}  sizes={sizes}")


def main(argv: list[str]) -> int:
    if "--windows-ico" in argv:
        windows_ico()
        return 0
    print("Generating Thelxis brand assets")
    save_png(app_icon(1024), ICON_DIR / "app_icon.png")
    # macOS wants ~100px of transparent margin + a soft shadow around the tile
    save_png(app_icon(1024, inset=0.0977, shadow=True), ICON_DIR / "app_icon_macos.png")
    save_png(foreground(1024), ICON_DIR / "app_icon_foreground.png")
    save_png(monochrome(1024), ICON_DIR / "app_icon_monochrome.png")
    save_png(tray(64, (255, 255, 255)), ICON_DIR / "tray.png")
    save_png(tray(64, (0, 0, 0)), ICON_DIR / "tray_template.png")
    write_ico(ICON_DIR / "tray.ico", [tray(s, (255, 255, 255)) for s in (16, 24, 32, 48, 64, 256)])
    print(f"  wrote {(ICON_DIR / 'tray.ico').relative_to(ROOT)}  sizes=16,24,32,48,64,256")
    (ICON_DIR / "logo.svg").write_text(logo_svg(), encoding="utf-8")
    print("  wrote app/assets/icon/logo.svg")
    save_png(app_icon(512), LINUX_PNG)
    windows_ico()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
