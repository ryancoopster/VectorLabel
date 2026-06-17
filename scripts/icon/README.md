# App icon

The VectorLabel icon is a "VL" monogram — a bold **L** stacked over an inverted
**V** (the flipped "V") — white on a black squircle. The same mark, monochrome,
is the menu-bar status item: a template image that auto-tints to light/dark menu
bars.

## Regenerate

```sh
scripts/icon/build-icon.sh
```

This rewrites the two committed assets:

- `MacApp/Sources/AppIcon.icns` — Finder/Dock icon (`CFBundleIconFile=AppIcon`)
- `MacApp/Sources/MenuBarIcon.png` — menu-bar glyph (set `isTemplate` at runtime)

Commit them, then run `scripts/package-app.sh` (or `scripts/install.sh`) to bundle
the new icon into the `.app`. (macOS caches bundle icons — if Finder still shows
the old one, `touch /Applications/VectorLabel.app` or relaunch.)

## Requirements

- **macOS** — uses `qlmanage` (SVG raster), `sips`, and `iconutil`, all built in.
- **Python Pillow** — `pip3 install pillow` (squircle mask + transparency keying).

## Editing the mark

All geometry lives in the constants at the top of `glyph.py`:
`THICK` (stroke weight), `L` (the letter L), `V` (the inverted V), and
`SQUIRCLE_MARGIN` / `SQUIRCLE_N` (the squircle shape). Change them and re-run
`build-icon.sh`.

## Pipeline

```
glyph.py (SVG)  ──qlmanage──▶  PNG  ──Pillow──▶  squircle mask / white-key
                                                      │
                                   sips ─▶ iconset ─▶ iconutil ─▶ AppIcon.icns
                                                      └────────▶ MenuBarIcon.png
```

The art is rendered full-bleed (background fills the whole canvas) so QuickLook
adds no drop shadow; the rounded-square (superellipse) edge is applied by Pillow.
