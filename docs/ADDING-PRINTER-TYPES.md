# Adding a New Printer Type to VectorLabel

This document is written **for an AI coding agent** (Claude Code) running inside the
VectorLabel repository. A human contributor will hand you this file and ask you to
add support for a **new printer type/model** — either another Brady model or a
different vendor. Follow the steps in order. Read the cited files before you edit
them; the architecture has several non-obvious seams, and the code comments contain
the ground truth.

VectorLabel is a Swift Package (`Package.swift` at the repo root, sources under
`MacApp/Sources/`). It is a four-app menu-bar suite. Today it supports **Brady
M610 / M611** thermal printers over USB via **libusb**.

> Throughout, paths are repo-relative unless noted. Build/test from the repo root
> (`swift build`, `swift test`) — there is no separate `MacApp/` package; `MacApp`
> is just the source folder.

---

## 1. Overview — the printing architecture at a glance

Printing flows **front-end app → IPC print queue → Engine → PrinterManager →
BradyUSB → printer**. Status flows back the other way as a published JSON file.

```
┌─────────────────────────┐
│ Front-end apps           │  AutoPrint, CustomDesigner, TemplateDesigner
│  (no libusb)             │  Each renders labels to VGL bytes and submits jobs.
└───────────┬─────────────┘
            │  PrintJobFile (labels = [Data], each a complete VGL byte buffer)
            ▼
┌─────────────────────────┐
│ IPC PrintQueue (files)   │  MacApp/Sources/Core/IPC/PrintQueue.swift
│  queue/ processing/ …    │  Atomic temp→rename publish; FSEvents watcher.
│  status/printers.json    │  ◄── Engine publishes printer + cassette status here.
└───────────┬─────────────┘
            │  PrintQueueWatcher.claim() (atomic move == lock)
            ▼
┌─────────────────────────┐
│ Engine (the ONLY app     │  MacApp/Sources/Engine/VectorLabelEngineApp.swift
│  that links libusb)      │  Consumes jobs, owns the device, publishes status.
└───────────┬─────────────┘
            │  PrinterManager.submit(jobs:…)
            ▼
┌─────────────────────────┐
│ PrinterManager           │  MacApp/Sources/EngineKit/PrinterManager.swift
│  scan loop, job queue,   │  USB enumeration (5 s timer), per-printer serial
│  cassette detection      │  queue, cancel, progress pacing, SmartCell reads.
└───────────┬─────────────┘
            │  BradyUSB.openPrinterByID / sendJob / querySmartCell
            ▼
┌─────────────────────────┐
│ BradyUSB (libusb)        │  MacApp/Sources/EngineKit/BradyUSB.swift
│  enumerate/open/send     │  USB transport + SmartCell parse.
└───────────┬─────────────┘
            ▼
        Brady printer (USB, VID 0x0E2E)
```

Key files and their roles (all paths under `MacApp/Sources/`):

| File | Role |
|---|---|
| `UI/PrintBackend.swift` | The `PrintBackend` protocol — the UI's abstract surface over status + submit. Defined in Core IPC types only, so the UI never links libusb. |
| `UI/IPCPrintBackend.swift` | The Core-only `PrintBackend` impl: reads `printers.json`, submits via `PrintQueue`. This is what the front-end apps actually use. |
| `Core/IPC/PrintQueue.swift` | The file-based queue + `PrintQueueWatcher` (Engine-side consumer) + status publish/read + control channel (cancel). |
| `Core/IPC/PrintJobFile.swift` | The `PrintJobFile` wire format (labels are base64 `Data`) and the IPC `CutMode` enum. |
| `Core/IPC/PrinterStatusFile.swift` | `PrinterStatusFile` / `PrinterStatusEntry` / `CassetteStatus` / `ActiveJobStatus` — the published status shape. **`PrinterStatusEntry.model` is the model string** ("M610" / "M611"). |
| `Engine/VectorLabelEngineApp.swift` | The Engine `AppDelegate`: wires the queue consumer, control watcher, and status publisher; resolves which printer a job runs on. |
| `EngineKit/PrinterManager.swift` | `PrinterDevice` model, USB scan loop, `submit(jobs:…)` dispatch, cassette cache, calibration grid. |
| `EngineKit/BradyUSB.swift` | libusb transport: `enumeratePrinters`, `openPrinterByID`, `sendJob`, `labelsRemaining`, `querySmartCell`/`parseSmartCell`. Holds the VID/PID table. |
| `EngineKit/StatusMapping.swift` | Maps EngineKit's live (non-Codable) hardware types onto the Core IPC status types (`asCassetteStatus`, `asStatusEntry`, `currentStatusFile`). |
| `Core/BradyVGL.swift` | The byte-format encoder: pixel buffer → VGL raster job, RLE, cut/feed commands (the last two are gated behind UNVERIFIED flags). |
| `Core/LabelTemplate.swift` | `LabelRenderer` — renders `VLTemplate + WireRecord` to a mono pixel buffer; applies `feedRotation` and the calibration offset. |
| `Core/SupplyCatalog.swift` | The editable supply-catalog model: `SupplyCatalog → SupplyGroup → SupplyCategory → Supply → SupplyPartNumber`. |
| `Core/SupplyCatalogDefaults.swift` | `SupplyCatalog.makeDefault()` — the factory seed (one `SupplyGroup` for `["M610", "M611"]`). |
| `Core/SupplyCatalogStore.swift` | Persists the catalog to Application Support; `BradyCatalog` reads its thread-safe `snapshot`. |
| `Core/BradyCatalog.swift` | A thin **façade** over the active catalog (lookups by part number). Not a data source anymore. |

### Target / module boundaries (important)

`Package.swift` enforces the libusb boundary deliberately:

- `VectorLabelCore` (target `Core`) — pure logic + IPC types. **No libusb.**
- `VectorLabelEngineKit` (target `EngineKit`) — depends on `Core` **and `CLibUSB`**.
  This is the only library target that links libusb.
- `VectorLabelUI` (target `UI`) — depends on `Core` only. **No libusb.**
- `VectorLabelEngine` executable — depends on `Core`, `EngineKit`, `UI`. **The only
  executable that links libusb / owns the device.**
- `VectorLabelAutoPrint` / `…TemplateDesigner` / `…CustomDesigner` executables —
  depend on `Core` + `UI` only.

`CLibUSB` is a `systemLibrary` target (`MacApp/Sources/CLibUSB/module.modulemap`)
pointing at the Homebrew `libusb-1.0` header. **Keep new USB code inside `EngineKit`**
so the front-ends stay libusb-free; if you break that boundary the front-end apps
won't link.

---

## 2. What "a printer type" means here

A printer type is the combination of **five** things. To add one, you touch each:

1. **A model string.** `PrinterStatusEntry.model` (`Core/IPC/PrinterStatusFile.swift`)
   is a free-form `String` — `"M610"`, `"M611"`. It originates in
   `PrinterDevice.model` (`EngineKit/PrinterManager.swift`) which is set by
   `BradyUSB.modelFor(productID:)` during enumeration. The model string is the join
   key that selects a supply group (see point 5) and is what front-ends display.

2. **USB identity + status reporting.** A printer is discovered by USB
   VID/PID/interface-class in `BradyUSB.enumeratePrinters()`, opened by composite id
   `"<vid>:<pid>:<serial>"` in `openPrinterByID`, and its `status`
   (`ready`/`busy`/`offline`) and loaded **cassette** (`CassetteStatus`) are published
   into `printers.json` by the Engine via `StatusMapping`. Cassette data comes from
   the Brady SmartCell chip (`querySmartCell` / `parseSmartCell`).

3. **A byte protocol.** The label bytes are produced by `BradyVGL.buildPrintJob`
   (`Core/BradyVGL.swift`). The front-end renders pixels (`LabelRenderer.render`),
   converts them to a VGL byte buffer, and ships the buffer as one element of
   `PrintJobFile.labels`. **The Engine is a pure transport — it never re-encodes the
   bytes**, it only paces `BradyUSB.sendJob` over USB. So a printer with a *different*
   wire protocol needs its own encoder *at the front-end render step*, not in the
   Engine.

4. **Feed rotation + cut/feed modes.** Some supplies feed rotated 90° on the roll;
   `LabelRenderer.render` rotates the raster to match using
   `BradyCatalog.feedRotationDeg(forPartNumber:)`. Cut mode flows end-to-end
   (`PrintJobFile.cutMode` → `BradyVGL.vglCutMode` → `BradyVGL.cutCommand`) but the
   actual cut/feed **bytes are gated OFF** behind `cutCommandEnabled` /
   `feedLengthCommandEnabled` until verified on hardware (see §4).

5. **A supply group.** `SupplyCatalog` (`Core/SupplyCatalog.swift`) organizes
   supplies into `SupplyGroup`s, each assigned to printer models via
   `printerModels: [String]`. `SupplyGroup.serves(model:)` matches the printer's
   reported `model` **case-insensitively**. The default seed
   (`SupplyCatalog.makeDefault()`) ships one group, `"Brady M6 / M7"`, serving
   `["M610", "M611"]`. A new printer type needs a group whose `printerModels`
   contains its model string — otherwise `SupplyCatalog.group(forModel:)` falls back
   to the first group and offers the wrong supplies.

If your new printer is **another Brady model** that speaks VGL and uses SmartCell
cassettes, you mostly reuse the existing pipeline and only touch points 1, 2, and 5.
If it is a **different vendor** with a different protocol, you additionally need a new
encoder (point 3) and likely a new USB/transport path and status mapping (see the
caveats at the end of §3).

---

## 3. Step-by-step: adding a new printer type

Work in a branch (the repo's default branch is `main`; do not commit to `main`
directly — see §5). Do the steps in this order; build after each major step.

### (a) Hardware driver + USB enumeration & status polling

Read `EngineKit/BradyUSB.swift` end to end first — especially the header comment on
the M611 PID being **UNVERIFIED** and the `deviceIsPrinter` fallback logic.

**If the new printer is on the Brady VID (`0x0E2E`):**

1. Add its PID → model mapping to `BradyUSB.knownModels`:
   ```swift
   static let knownModels: [(pid: UInt16, model: String)] = [
       (0x010B, "M610"),
       (0x010C, "M611"),   // UNVERIFIED PID
       (0x0XXX, "M7xx"),   // ← your new model + its confirmed PID
   ]
   ```
   `modelFor(productID:)` returns the matched model for a known PID and falls back to
   `"M611"` for an unrecognized Brady device. If you add a model whose PID you have
   **not** hardware-confirmed, follow the existing pattern: leave a `// UNVERIFIED`
   comment, and rely on the printer-class-interface fallback in `deviceIsPrinter` so
   it's still surfaced. Confirm the PID by plugging in the printer and running
   `system_profiler SPUSBDataType` (note `idProduct`).

2. `enumeratePrinters()` already accepts any Brady-VID device that presents a
   USB-printer-class interface, so a new Brady model is detected even before you know
   its PID. No change needed there beyond the `knownModels` entry for a clean model
   name. The composite id is `"<vid>:<pid>:<serial>"`.

3. **Status polling** is automatic: `PrinterManager.startScan()` runs
   `performScan()` on a 5 s timer (`scanTimer`), merges discovered devices, marks
   missing ones `offline` for one cycle, and auto-detects the cassette on a fresh
   connect (`refreshCassette`). Your new model rides this loop with no changes,
   provided enumeration returns it.

**If the new printer is a different vendor / transport:**

- Add a new VID and a parallel enumeration path in `BradyUSB` (or, cleaner, add a
  sibling type in `EngineKit`, e.g. `AcmeUSB.swift`, with the same shape:
  `enumeratePrinters() -> [PrinterDevice]`, `openPrinterByID`, `sendJob`,
  `labelsRemaining`, and cassette/status query). Have `PrinterManager.performScan()`
  merge results from both enumerators into the single `printers` array.
- Keep all of this inside the `EngineKit` target so libusb stays out of the
  front-ends.
- The per-printer **serial dispatch queue** (`BradyUSB.deviceQueue(for:)`) is what
  serializes device access; reuse the same pattern so prints and status reads to one
  device never overlap while different printers run concurrently.

### (b) Report the model + cassette via PrinterStatusFile

This is mostly automatic through `EngineKit/StatusMapping.swift`:

- `PrinterDevice.asStatusEntry(cassette:activeJobCount:)` copies `model`, `name`,
  `serial`, `status` into a `PrinterStatusEntry`. As long as enumeration set
  `model` correctly (step a), the published `model` is correct.
- `BradyUSB.SmartCellInfo.asCassetteStatus()` maps a SmartCell read to
  `CassetteStatus`. Note the documented quirk: `SmartCellInfo` carries no
  `printableHeightMils`, so `asCassetteStatus()` sets it equal to the label height.
- `PrinterManager.currentStatusFile()` assembles the whole `PrinterStatusFile`; the
  Engine republishes it (debounced) whenever `$printers`, `$cassettes`, or
  `$activeJobs` change (`startStatusPublisher` in `VectorLabelEngineApp.swift`).

**You only need new code here if your printer reports cassette/supply data
differently** (not Brady SmartCell). In that case, produce a `CassetteStatus`
yourself from whatever the device exposes and feed it into the status entry. If the
printer reports nothing, pass `cassette: nil` — front-ends already render the
"no cassette detected" state, and the user selects the supply manually.

### (c) Byte-format encoder (reuse BradyVGL, or add a new one)

Read `Core/BradyVGL.swift`. `buildPrintJob(pixels:width:height:cutMode:)` takes a
1-byte-per-pixel mono buffer (`0xFF` = ink, `0x00` = white), emits the VGL job
(`ESC X` start, optional feed/cut commands, per-column raster lines with RLE/raw
selection, `ESC E` end page, `ESC D` end job). The RLE polarity is hardware-validated
(`0x80` = black run) — **do not "fix" it** to match Brady's (wrong) SDK comment.

- **Same protocol (another Brady VGL printer):** reuse `BradyVGL.buildPrintJob`
  unchanged. The front-end already calls it after `LabelRenderer.render`; nothing to
  do here.
- **Different protocol:** add a sibling encoder in `Core` (e.g. `AcmeESCPOS.swift`,
  `Core/`), exposing `buildPrintJob(pixels:width:height:…) -> [UInt8]` with the same
  input contract (mono pixel buffer). Then the render-and-submit code in the
  front-end must choose the encoder based on the target printer's model. Today that
  selection point is in the front-end print flow (the WKWebView print bridge in
  `UI/PrintWindowController.swift` / the designers), which renders and submits
  `PrintJobFile`s. Add a small dispatch: `model → encoder`. Keep the encoder in
  `Core` so both the front-end and any in-process caller can reach it without
  importing EngineKit.

> **Architectural caveat:** because the Engine treats `labels` as opaque bytes, the
> protocol decision is made *before* the job reaches the queue. There is no
> per-model encoder registry today — the system assumes one protocol (VGL). Adding a
> second protocol means introducing that dispatch in the front-end render path; grep
> for `BradyVGL.buildPrintJob` and `LabelRenderer.render` to find the call sites.

### (d) Wire feed rotation / cut modes

- **Feed rotation** is data-driven per part number: `SupplyPartNumber.rotate90`
  drives `BradyCatalog.feedRotationDeg(forPartNumber:)`, which `LabelRenderer.render`
  reads to rotate the raster 90° (`Core/LabelTemplate.swift`, the `feedRotation`
  block). So you set rotation in the **supply group** (step e), not in code — set
  `rotate90: true` on the part numbers that feed rotated.
- **Cut mode** flows `PrintJobFile.cutMode` (IPC `CutMode`:
  `afterJobLast`/`eachLabel`/`never`) → `BradyVGL.vglCutMode(forIPCRawValue:index:total:)`
  → per-label `BradyVGL.CutMode` → `BradyVGL.cutCommand(for:)`. The emission is gated
  by `BradyVGL.cutCommandEnabled` (default `false`). **Leave it false** unless you
  have hardware-confirmed the cut bytes for your printer (see §4). Continuous
  feed-length is the same: `feedLengthCommand` gated by `feedLengthCommandEnabled`
  (default `false`); the raster height already encodes label length.
- If your printer's cut/feed bytes differ from Brady's `ESC M <mode> 00`, put the new
  bytes inside `cutCommand(for:)` / `feedLengthCommand(lengthPixels:)` (or your new
  encoder's equivalents) — those are the single source of truth for the sequence.

### (e) Add a supply group for the model

Two ways; do **both** consideration steps:

1. **For the shipped default** (so a fresh install knows about the printer): extend
   `SupplyCatalog.makeDefault()` in `Core/SupplyCatalogDefaults.swift`. Today it
   builds one `SupplyGroup`:
   ```swift
   let group = SupplyGroup(name: "Brady M6 / M7", printerModels: ["M610", "M611"],
                           categories: categories)
   return SupplyCatalog(version: 1, groups: [group],
                        coreEquivalences: ["109-427": "33-427"])
   ```
   - If the new model uses the **same supplies** as M610/M611, just add its model
     string to that group's `printerModels` (e.g. `["M610", "M611", "M7xx"]`).
   - If it uses **different supplies**, build a second `SupplyGroup` (its own
     `categories` of `Supply` rows, each with `SupplyPartNumber`s) and append it:
     `groups: [group, newGroup]`. Follow the existing `Row` → `Supply` grouping
     pattern in `makeDefault()` (die-cut grouped by geometry, continuous grouped by
     width). Set `rotate90: true` on parts that feed rotated; set
     `kind: .continuous` + `rollLengthFeet` for tapes whose length the user sets at
     print time.

2. **For an existing user** (who already has a saved `SupplyCatalog.json` in
   Application Support): the seed only applies on first run / "Restore defaults". The
   editable catalog is edited live in **Engine ▸ Preferences ▸ Supplies** (the editor
   is `Engine/SupplyCatalogEditor.swift`; `addGroup()` adds a group and the
   `printerModels` field is edited as a comma-separated list). Document for the
   contributor that existing users add the group there, or hit "Restore defaults".

**Critical join:** the group's `printerModels` entry must **exactly match the model
string** your enumeration sets in `PrinterDevice.model` (case-insensitive). If
enumeration reports `"M712"` but the group lists `"M7"`, `group(forModel:)` won't
match and the printer gets the fallback (first) group's supplies. Verify the two
strings line up.

> Note: `SupplyCatalogStore.webCatalogJSON(forModel:)` projects a group's supplies
> into the web designer/print UIs. It's currently invoked with `forModel: ""` at the
> call sites (`UI/PrintWindowController.swift`, `UI/DesignerWindowController.swift`),
> which falls back to the first group. If you add a distinct group for a new model
> and want the web UI to show *that* group's supplies when *that* printer is
> connected, you'll also need to thread the connected printer's `model` into those
> calls instead of `""`. Flag this to the contributor if the new group's supplies
> differ from the first group's.

### (f) Calibration considerations

- The per-printer calibration offset is keyed by **serial** (the trailing segment of
  the composite id): see `AppSettings.calibrationOffset(forSerial:)` used in
  `PrinterManager.printCalibrationGrid` and applied as the `offset` argument in
  `LabelRenderer.render`. A new printer type inherits this automatically — each
  physical unit gets its own offset by serial.
- `PrinterManager.calibrationSize(for:)` picks the label size for the calibration
  grid from the detected cassette (matched by `BradyCatalog.core`) and falls back to
  `"BM-32-427"`. If your new printer's default/most-common supply differs, consider
  adjusting that fallback or making it model-aware so the grid prints on a sane size
  when no cassette is detected.
- `pixelWidth`/`pixelHeight` assume **300 DPI** (`BradyLabelSize.dpi`,
  `SmartCellInfo.pixelWidth`). If your printer is not 300 DPI, this is a real change:
  DPI is currently a hard-coded constant in several places (`BradyLabelSize.dpi`,
  `SmartCellInfo` pixel computations, `LabelRenderer` `size.dpi`). Grep for `300` and
  `dpi` and make DPI model-driven before relying on calibrated output.

---

## 4. Testing

Run the build and the test suite from the repo root after each major step:

```bash
swift build          # or: scripts/build.sh   (stamps the in-app version first)
swift test           # runs MacApp/Tests (target VectorLabelTests, Core-only)
```

> The test target (`VectorLabelTests` in `Package.swift`) depends on
> `VectorLabelCore` only — it does **not** link libusb, so the USB code is **not**
> exercised by `swift test`. Tests cover the Core logic: catalog lookups, geometry,
> VGL encoding, formula engine, etc. (see `MacApp/Tests/FoundationTests.swift`).

### Tests to add

- **Catalog/model join** (Core, no hardware): add a test that
  `SupplyCatalog.makeDefault().group(forModel: "<your-model>")` returns the intended
  group, and that `SupplyGroup.serves(model:)` is case-insensitive. Mirror the
  existing `testDefaultCatalogPopulated` / `testBradyGeometryPinned` style in
  `FoundationTests.swift`.
- **Geometry/rotation pinning** for any new supplies you seed: assert
  `BradyCatalog.size(forPartNumber:)` returns the right width/height/printable and
  `feedRotationDeg(forPartNumber:)` is `0` or `90` as intended (see
  `testBradyGeometryPinned`).
- **Encoder** (if you added a new protocol): pin a small golden byte vector for
  `buildPrintJob` on a tiny known pixel buffer, the way the project pins VGL behavior.
- **`labelsPerRoll` / `core` equivalences** if you add new part-number families that
  share a core.

### Test-printing safely

- The cut and feed-length commands are **gated off by default**
  (`BradyVGL.cutCommandEnabled == false`, `feedLengthCommandEnabled == false`) because
  the byte sequences are **UNVERIFIED** on real cutter-equipped hardware. **Respect
  this pattern.** When you add or change cut/feed bytes:
  - Keep them behind the existing boolean flags (or add an equivalent flag for a new
    encoder). Default the flag to `false`.
  - Only flip the flag to `true` after you have physically confirmed the byte
    sequence on the target hardware, and update the `// ⚠️ UNVERIFIED` comments
    accordingly.
  - With the flags off, `cutCommand`/`feedLengthCommand` return empty arrays and log
    that they were suppressed — the wire stream stays byte-for-byte unchanged, so a
    test print on die-cut stock is safe.
- To exercise the full device path, build and install the suite, then print from a
  front-end against the real printer:
  ```bash
  scripts/install.sh                 # build + package + install + relaunch (pulls main first)
  scripts/install.sh --no-pull       # skip the git pull
  VARIANT=beta scripts/install.sh    # installs the "VectorLabel Beta" suite side-by-side
  ```
  The beta variant installs into `/Applications/VectorLabel Beta/` and uses a
  separate Application Support directory, so you can test a new printer type without
  disturbing a production install. Only **one** Engine can own the USB device at a
  time — quit any other running Engine first.
- Use the **calibration grid** (Engine menu / Preferences) as your first physical
  print on a new printer: it renders the grid for the detected (or fallback) supply
  and exercises render → VGL → USB without needing a data export.

---

## 5. Opening the pull request

Keep this short. When the change builds, `swift test` passes, and (if you have
hardware) a calibration/test print succeeds:

1. Make sure you are on a feature branch, not `main`.
2. Commit your changes with a clear message describing the new printer type.
3. Push and open a PR against `origin` (`github.com/ryancoopster/VectorLabel`).

For the exact GitHub + Claude-Code mechanics (branch naming, commit/PR conventions,
how to drive the PR from Claude Code), follow the companion guide:

→ **[`docs/CONTRIBUTING-VIA-CLAUDE-CODE.md`](./CONTRIBUTING-VIA-CLAUDE-CODE.md)**

In the PR description, call out explicitly:

- The new **model string** and how it's detected (VID/PID, or interface-class
  fallback), and whether the PID is **hardware-confirmed** or still UNVERIFIED.
- Whether you reused `BradyVGL` or added a new encoder.
- The new/edited **supply group** and that its `printerModels` matches the detected
  model string.
- The state of the cut/feed flags (kept off unless hardware-verified) and any DPI
  assumptions if the printer is not 300 DPI.
