# Brother P-touch Driver — Status & Test Matrix

Running record of what is implemented and what is hardware-verified for the Brother
PT-series drivers in VectorLabel. Update the matrix as models are tested on real units.

See also: `docs/WRITING-A-PRINTER-DRIVER.md` (driver contract) and the field guide in
`Downloads/brother-ptouch-handoff*/brother-ptouch-integration-handoff.md` (protocol
provenance, the half-cut trophy, the one-job-hang footgun).

---

## Architecture

- **Module:** `MacApp/Sources/PrinterBrother/` — one self-contained target.
  - `BrotherPT.swift` — the **classic** raster dialect (PT-E550W / PT-P750W). A
    byte-for-byte Swift port of the validated Python (`brother_pt.py`), pinned by the
    golden vectors in `MacApp/Tests/BrotherPTTests.swift`. Native **180 DPI**.
  - `BrotherUSB.swift` — libusb transport: claim iface 0 (detach the macOS
    `AppleUSBPrinter` kext, **no reattach**), endpoints by **direction**, **64-byte**
    chunks, 30 s write timeout, status read with empty-read retry + drain.
  - `PTE550WModule.swift` — the `PrinterModule` for the PT-E550W.
- **Render contract:** the app renders at the **900-DPI master** (`RenderDPI.master`);
  the module downscales to 180 (`MonoRaster.downscale`) and **transposes** the
  reading-orientation raster into the tape frame (across-tape → print-head pins,
  along-tape → raster lines) before framing the classic job.
- **Supplies:** the **"Brother P-touch"** supply group (continuous TZe tapes, all six
  widths) in `SupplyCatalogDefaults.brotherPTouchGroup()`. Printable width per tape =
  `printWidth(mm)/180"` (less than the tape width — the head has an unprintable margin
  on both sides). Added to existing installs via `SupplyCatalog.migrated()` (v1→v2).

## Tape geometry (180 DPI, 128-pin head → 16 bytes/line)

| Tape | Margin/side (pins) | Printable pins (`128−2·m`) | Printable width |
|------|--------------------|----------------------------|-----------------|
| 3.5 mm | 52 | 24 | 0.133″ |
| 6 mm | 48 | 32 | 0.178″ |
| 9 mm | 39 | 50 | 0.278″ |
| 12 mm | 29 | 70 | 0.389″ |
| 18 mm | 8 | 112 | 0.622″ |
| 24 mm | 0 | 128 | 0.711″ |

---

## Model matrix

Legend: ✅ verified on hardware · 🟡 implemented, not yet hardware-tested · ⬜ not started · ➖ n/a

| Model | PID | Dialect | Driver | Enumerate (USB) | Status read | Print 1 label | Half-cut strip | Orientation | Cut behavior |
|-------|-----|---------|--------|------|------|------|------|------|------|
| **PT-E550W** | `04F9:2060` | classic | 🟡 `PTE550WModule` | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 *unverified* | 🟡 *unverified* |
| PT-P750W | `04F9:2062` | classic | ⬜ (shares `BrotherPT`) | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| PT-E560BT | `04F9:2203` | **D460BT** | ⬜ (needs `BrotherPT` D460BT path) | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |

### What is verified *offline* (unit tests, no hardware)

- ✅ PackBits + raster-line framing byte-identical to the Python reference.
- ✅ The **171-byte golden job** (12 mm, 4-px image) matches the Python golden vector.
- ✅ `printWidth`/margin table, `nearestTape`, batch-stream framing (one init, half-cut
  on intermediates only, single trailing `0x1A`), status parsing.
- ✅ `MonoRaster.downscale` 900→180 is exact for every TZe width (÷5), hairlines survive.
- ✅ `RenderedLabel` dpi field + compressed round-trip + legacy decode.

### What still needs a real PT-E550W

1. **USB**: kernel-detach + claim on macOS; endpoint discovery; a clean 64-byte streamed print.
2. **Orientation**: confirm text reads the right way along/across the tape. If mirrored or
   upside-down, flip `PTE550WModule.mirrorAlong` / `mirrorAcross` (and re-test).
3. **Cut**: confirm full-job = one strip with a clean final cut; `eachLabel` = scored
   half-cuts between labels; single-label `afterJobLast` = cut only the last label.
   **Cut *suppression* (`CutMode.never`) uses the advanced-mode nocut bit (0x10) and is
   hardware-UNVERIFIED on the classic dialect** — the `0x1A` terminator may still
   feed+cut. Verify whether `.never` actually leaves the strip uncut.
4. **Status/media auto-detect**: confirm `ESC i S` returns the loaded tape width + errors.
5. **Drain rule**: confirm the post-send status drain lets the last label finish before the
   Engine closes the port (no "printing… please wait" hang).
6. **Supply part numbers**: the seeded TZe SKUs (esp. `TZe-3.5mm`) are placeholders/best-effort
   — verify/replace in Preferences ▸ Supplies.

> ⚠️ Do **not** feed the classic dialect to a PT-E560BT (PID `04F9:2203`) — it speaks the
> D460BT dialect and will print one job then hang until power-cycled. The module's PID set
> (`PTE550WModule.productIDs`) is `0x2060` only, so it won't claim a 560BT.

## Next models

- **PT-P750W**: same classic dialect — add `0x2062` to a module (or a `PTP750WModule`) once a
  unit is available; `BrotherPT` needs no changes.
- **PT-E560BT**: add the D460BT builders to `BrotherPT` (n9=0x02 load-bearing byte, 7-byte
  magic margin, uncompressed raster, the two-job half-cut strip + standalone cutter job,
  status auto-notify OFF, full post-print drain) — all detailed in the handoff §6–§7.
