#!/usr/bin/env python3
"""VectorLabel icon generator — single source of truth for the mark.

The mark is a monogram stacked over an inverted V (the flipped "V"), white on a
black squircle. There are two variants:
    "L"  — a bold L over the chevron (Engine / Auto Print / Template Designer).
    "CL" — a C and an L over the chevron (the new Custom Designer / "CL" mark).
The same mark, monochrome, is the menu-bar status item (a template image that
auto-tints to light/dark menu bars).

This script only emits SVGs and does the Pillow image ops; build-icon.sh drives
the macOS rasterization (qlmanage) and .icns assembly (sips + iconutil). To tweak
the mark, edit the GEOMETRY constants below and re-run build-icon.sh.

Usage (normally invoked by build-icon.sh):
    glyph.py svg-app  <out.svg> [variant]   # black field + white glyph (app icon)
    glyph.py svg-menu <out.svg> [variant]   # white field + black glyph (menu source)
    glyph.py mask     <in.png> <out.png> [size]   # squircle-mask the app icon
    glyph.py menu     <in.png> <out.png>          # key white->transparent template
where [variant] is "L" (default) or "CL".
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

# CL variant geometry — a C (left) + L (right) sharing the L's vertical band.
# Band: top y=198 .. bottom y=408 (same as the L mark), centred above the chevron.
CL_TOP, CL_BOT = 198.0, 408.0
CL_CR = 92.0                         # C arc radius (slightly inset from the band)
CL_CX = 360.0                        # C centre x (left of centre)
CL_CY = (CL_TOP + CL_BOT) / 2.0      # C centre y (band midline)
CL_GAP = 58.0                        # C-arc opening half-angle (degrees) on the right
CL_LSTEM = 590.0                     # L stem x (right of the C)
CL_LFOOT = 742.0                     # L foot x (foot extends right)


def _stroke(pts, color):
    d = "M %.1f %.1f " % pts[0] + " ".join("L %.1f %.1f" % p for p in pts[1:])
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{THICK}" '
            f'stroke-linecap="butt" stroke-linejoin="miter" stroke-miterlimit="6"/>')


def _arc(cxc, cyc, r, a0, a1, color):
    """An open arc from angle a0 to a1 (degrees, CCW). Round caps read as a C."""
    x0 = cxc + r * math.cos(math.radians(a0)); y0 = cyc - r * math.sin(math.radians(a0))
    x1 = cxc + r * math.cos(math.radians(a1)); y1 = cyc - r * math.sin(math.radians(a1))
    sweep = a1 - a0
    large = 1 if abs(sweep) > 180 else 0
    # SVG sweep-flag 0 = CCW in screen coords (y down); we go CCW so use 0.
    d = f"M {x0:.1f} {y0:.1f} A {r:.1f} {r:.1f} 0 {large} 0 {x1:.1f} {y1:.1f}"
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{THICK}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def glyph(color):
    sx, ty, by, fx = L
    ax, vby, hw = V
    return (_stroke([(sx, ty), (sx, by), (fx, by)], color) +             # L
            _stroke([(cx - hw, vby), (cx, ax), (cx + hw, vby)], color))   # inverted V


def glyph_cl(color):
    ax, vby, hw = V
    # C: an arc open on the right (gap centred at 0°), sweeping CCW.
    c = _arc(CL_CX, CL_CY, CL_CR, CL_GAP, 360.0 - CL_GAP, color)
    # L: stem + foot, same band as the C.
    l = _stroke([(CL_LSTEM, CL_TOP), (CL_LSTEM, CL_BOT), (CL_LFOOT, CL_BOT)], color)
    chevron = _stroke([(cx - hw, vby), (cx, ax), (cx + hw, vby)], color)
    return c + l + chevron


def glyph_label(text, color):
    # Two-letter tag to the RIGHT of the L mark, at the L's height (e.g. "CD"/"TD"),
    # so the Custom and Template Designer dock icons are clearly distinct ("L CD").
    return (f'<text x="690" y="392" text-anchor="start" '
            f'font-family="Helvetica Neue, Helvetica, Arial, sans-serif" '
            f'font-weight="800" font-size="210" letter-spacing="-6" '
            f'fill="{color}">{text}</text>')


def svg(bg, fg, variant="L"):
    if variant == "CL":
        body = glyph_cl(fg)
    elif variant in ("TD", "CD"):
        body = glyph(fg) + glyph_label(variant, fg)
    else:
        body = glyph(fg)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" '
            f'viewBox="0 0 {W} {W}"><rect width="{W}" height="{W}" fill="{bg}"/>'
            f'{body}</svg>')


def cmd_svg_app(out, variant="L"):  open(out, "w").write(svg("#000000", "#FFFFFF", variant))
def cmd_svg_menu(out, variant="L"): open(out, "w").write(svg("#FFFFFF", "#000000", variant))


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
    if   cmd == "svg-app":  cmd_svg_app(a[2], a[3] if len(a) > 3 else "L")
    elif cmd == "svg-menu": cmd_svg_menu(a[2], a[3] if len(a) > 3 else "L")
    elif cmd == "mask":     cmd_mask(a[2], a[3], a[4] if len(a) > 4 else 1024)
    elif cmd == "menu":     cmd_menu(a[2], a[3])
    else:
        print("unknown command:", cmd); sys.exit(1)


if __name__ == "__main__":
    main()
