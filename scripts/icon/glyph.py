#!/usr/bin/env python3
"""VectorLabel icon generator — single source of truth for the mark.

The mark is a "VL" monogram: a bold L stacked over an inverted V (the flipped
"V"), white on a black squircle. The same mark, monochrome, is the menu-bar
status item (a template image that auto-tints to light/dark menu bars).

This script only emits SVGs and does the Pillow image ops; build-icon.sh drives
the macOS rasterization (qlmanage) and .icns assembly (sips + iconutil). To tweak
the mark, edit the GEOMETRY constants below and re-run build-icon.sh.

Usage (normally invoked by build-icon.sh):
    glyph.py svg-app  <out.svg>          # black field + white glyph (app icon)
    glyph.py svg-menu <out.svg>          # white field + black glyph (menu source)
    glyph.py mask     <in.png> <out.png> [size]   # squircle-mask the app icon
    glyph.py menu     <in.png> <out.png>          # key white->transparent template
"""
import sys, math

# ── Geometry (1024 canvas) — edit here to change the mark ─────────────────────
W = 1024
cx = W / 2.0
THICK = 110                       # stroke weight for both letters
L = (cx - 110, 198, 408, cx + 138)   # L: stem_x, top_y, bottom_y, foot_x
V = (576, 822, 244)                  # inverted V (chevron): apex_y, bottom_y, half_width
SQUIRCLE_MARGIN = 40              # transparent margin around the squircle (1024 space)
SQUIRCLE_N = 5.0                  # superellipse exponent (~Apple squircle)


def _stroke(pts, color):
    d = "M %.1f %.1f " % pts[0] + " ".join("L %.1f %.1f" % p for p in pts[1:])
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{THICK}" '
            f'stroke-linecap="butt" stroke-linejoin="miter" stroke-miterlimit="6"/>')


def glyph(color):
    sx, ty, by, fx = L
    ax, vby, hw = V
    return (_stroke([(sx, ty), (sx, by), (fx, by)], color) +             # L
            _stroke([(cx - hw, vby), (cx, ax), (cx + hw, vby)], color))   # inverted V


def svg(bg, fg):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" '
            f'viewBox="0 0 {W} {W}"><rect width="{W}" height="{W}" fill="{bg}"/>'
            f'{glyph(fg)}</svg>')


def cmd_svg_app(out):  open(out, "w").write(svg("#000000", "#FFFFFF"))
def cmd_svg_menu(out): open(out, "w").write(svg("#FFFFFF", "#000000"))


def cmd_mask(src, out, size):
    """Mask the full-bleed art into an Apple-style squircle (superellipse)."""
    from PIL import Image, ImageDraw
    size = int(size); SS = 4; N = SQUIRCLE_N
    scale = size / 1024.0; big = size * SS
    a = (big - 2 * SQUIRCLE_MARGIN * scale * SS) / 2.0; c = big / 2.0
    pts = []
    for k in range(1440):
        th = 2 * math.pi * k / 1440; ct, st = math.cos(th), math.sin(th)
        pts.append((c + a * math.copysign(abs(ct) ** (2 / N), ct),
                    c + a * math.copysign(abs(st) ** (2 / N), st)))
    m = Image.new("L", (big, big), 0); ImageDraw.Draw(m).polygon(pts, fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    art = Image.open(src).convert("RGBA")
    if art.size != (size, size): art = art.resize((size, size), Image.LANCZOS)
    o = Image.new("RGBA", (size, size), (0, 0, 0, 0)); o.paste(art, (0, 0), m); o.save(out)


def cmd_menu(src, out):
    """Key the white field to transparency -> a tightly-cropped black template."""
    from PIL import Image
    im = Image.open(src).convert("L")   # black glyph on white
    w, h = im.size; rgba = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    s = im.load(); d = rgba.load()
    for y in range(h):
        for x in range(w):
            a = 255 - s[x, y]
            if a: d[x, y] = (0, 0, 0, a)
    g = rgba.crop(rgba.getbbox()); gw, gh = g.size
    side = max(gw, gh); pad = int(side * 0.10); canvas = side + 2 * pad
    o = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    o.paste(g, ((canvas - gw) // 2, (canvas - gh) // 2), g)
    o.resize((144, 144), Image.LANCZOS).save(out)


def main():
    a = sys.argv
    if len(a) < 2:
        print(__doc__); sys.exit(1)
    cmd = a[1]
    if   cmd == "svg-app":  cmd_svg_app(a[2])
    elif cmd == "svg-menu": cmd_svg_menu(a[2])
    elif cmd == "mask":     cmd_mask(a[2], a[3], a[4] if len(a) > 4 else 1024)
    elif cmd == "menu":     cmd_menu(a[2], a[3])
    else:
        print("unknown command:", cmd); sys.exit(1)


if __name__ == "__main__":
    main()
