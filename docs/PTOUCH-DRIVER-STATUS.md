# Brother P-touch Driver — Status & Test Matrix

Running record of what is implemented and what is hardware-verified for the Brother
PT-series drivers in VectorLabel. Update the matrix as models are tested on real units.

See also: `docs/WRITING-A-PRINTER-DRIVER.md` (driver contract) and the field guide in
`Downloads/brother-ptouch-handoff*/brother-ptouch-integration-handoff.md` (protocol
provenance, the half-cut trophy, the one-job-hang footgun).

---

## Architecture

- **Module:** `MacApp/Sources/PrinterBrother/` — one self-contained target.
  - `BrotherPT.swift` — BOTH raster dialects + shared raster prep. The **classic**
    dialect (PT-E550W / PT-P750W, PackBits) and the **D460BT** dialect (PT-E560BT,
    uncompressed, n9=0x02, magic margin, two-job half-cut strip), plus the shared
    `tapeRaster` (downscale + transpose) and `cassetteStatus`. A byte-for-byte Swift
    port of the validated Python (`brother_pt.py`), pinned by the golden vectors in
    `MacApp/Tests/BrotherPTTests.swift`. Native **180 DPI**.
  - `BrotherUSB.swift` — libusb transport (PID-agnostic): claim iface 0 (detach the
    macOS `AppleUSBPrinter` kext, **no reattach**), endpoints by **direction**,
    **64-byte** chunks, 30 s write timeout, status read with empty-read retry + drain.
  - `BrotherNet.swift` — raw TCP **9100** transport for the Wi-Fi "W" models.
  - `BrotherClassicModule.swift` — shared classic-dialect base; **`PTE550WModule`** and
    **`PTP750WModule`** are distinct `PrinterModule` subclasses (one per printer).
  - `PTE560BTModule.swift` — the D460BT `PrinterModule` (PT-E560BT, USB only).
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

| Model | PID | Dialect | Driver | Enumerate (USB) | Network (TCP 9100) | Status read | Print 1 label | Half-cut strip | Orientation | Cut behavior |
|-------|-----|---------|--------|------|------|------|------|------|------|------|
| **PT-E550W** | `04F9:2060` | classic | 🟡 `PTE550WModule` | 🟡 | 🟡 *9100 confirmed open; print untested* | 🟡 (USB only) | 🟡 | 🟡 | 🟡 *unverified* | 🟡 *unverified* |
| **PT-P750W** | `04F9:2062` | classic | 🟡 `PTP750WModule` | 🟡 | 🟡 (Wi-Fi model — same as 550W) | 🟡 (USB only) | 🟡 | 🟡 | 🟡 *unverified* | 🟡 *unverified* |
| **PT-E560BT** | `04F9:2203` | **D460BT** | 🟡 `PTE560BTModule` | 🟡 | ➖ (Bluetooth unit — no Wi-Fi/9100) | 🟡 (USB only) | 🟡 | 🟡 | 🟡 *unverified* | 🟡 *unverified* |

All three modules are implemented + offline-tested (golden vectors); **none are hardware-verified
yet** — test one model at a time. `PTE550WModule`/`PTP750WModule` share a `BrotherClassicModule`
base (classic dialect); `PTE560BTModule` is its own class on the D460BT dialect. Connection
methods covered by the handoff are **USB** (all) + raw **TCP 9100** for the Wi-Fi "W" models
(550W/750W, our addition). The E560BT is Bluetooth-only hardware; a Bluetooth transport is **not**
in the docs and is not implemented — it prints over USB.

### Network (TCP 9100)

`BrotherNet.swift` streams the same classic raster bytes to raw port **9100** (confirmed
open on a 550W's Wi-Fi at 192.168.86.32). Add a network PT in Preferences ▸ Printers ▸
**Add network printer** — enter the IP and pick **PT-E550W** as the model (the model field
routes the entry to the right driver; the M611 enumerate now filters to its own model so
the two don't collide). Limitations vs USB:
- **Print-only** — media/tape auto-detect (ESC i S) reads the USB IN endpoint, not exposed
  over the network. A network PT derives its tape from the rendered raster, so there's no
  loaded-cassette readout and the **die-cut→continuous re-map doesn't trigger** (it needs
  the loaded tape width). Use a continuous template, or USB, for that case.
- **Drain** is a short flush wait (TCP close doesn't abort a buffered job), not a status drain.

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
> D460BT dialect and will print one job then hang until power-cycled. Routing is by PID:
> `PTE550WModule` (`0x2060`) and `PTP750WModule` (`0x2062`) are classic-only; only
> `PTE560BTModule` claims `0x2203`, and it uses the D460BT builders exclusively.

## Per-model hardware test checklist (test one at a time)

For **each** model verify, in order: enumerate over USB (Preferences ▸ Printers); media
auto-detect (status read shows the loaded tape mm); a single label (orientation — text reads
the right way along/across the tape; if mirrored flip `mirrorAcross`, if upside-down flip
`mirrorAlong`); a multi-label half-cut strip (scored between, one full cut at the end); the
other cut modes (full-every-label, full-at-end, none). For the **W** models also test a
network print (add the IP in Preferences, model = that printer). The **E560BT** is the one to
watch for the one-job-hang — if it ever hangs on "printing… please wait," that's the classic
dialect leaking in (it shouldn't, but it's the canary).

## Future

- **PT-E560BT Bluetooth**: the unit is Bluetooth-capable but the handoff specifies only USB;
  a BLE/RFCOMM transport would be a separate effort (not in the docs). It prints over USB today.
- **Other D460BT-family models** (E310BT, D410/D460BT/D610BT): same dialect as the E560BT — add
  a module with the right PID; `BrotherPT`'s D460BT builders need no changes.
