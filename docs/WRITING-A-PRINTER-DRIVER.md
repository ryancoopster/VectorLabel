# Writing a Printer Driver for VectorLabel

This is the authoritative guide to the **driver layer**: how to add support for a new
printer, exactly how a driver communicates with the Engine, and the data structures the
contract is built on. It is written for both human contributors and future Claude sessions.

Everything here is verified against the source as of the M610/M611 implementation. Paths are
repo-relative; the package is `Package.swift` at the repo root, sources under `MacApp/Sources/`.
Build/test with `swift build` / `swift test` from the repo root.

> For the broader "add a printer end-to-end" walkthrough (UI, supply catalog, IPC), see
> `docs/ADDING-PRINTER-TYPES.md` — but note that doc predates this driver refactor and its
> *driver-layer* description (a central `BradyUSB`) is superseded by what's below.

---

## 1. The one-paragraph mental model

A **driver** is one type that conforms to `PrinterModule` (`MacApp/Sources/Core/Printing/PrinterModule.swift`)
and is registered with `PrinterModuleRegistry.shared`. The **Engine** owns the job lifecycle
(queue, cancel, Recent Prints, IPC, pre-flight, the menu UI) and is **completely
printer-agnostic** — it never branches on the model. For each print it hands the driver a
`DriverJob` (label content + the user's send mode + an open connection + a cancel check + a
progress sink) and calls `run(_:)`. The driver owns **how** it sends (one label at a time vs
one batch), pacing, completion detection, and transport. It reports back only `JobProgress`
(`.counter` / `.printing` / `.done`). That's the entire seam.

```
Front-end app ──PrintJobFile──▶ IPC queue ──▶ Engine (PrinterManager)
                                                   │  builds DriverJob, calls module.run(job)
                                                   ▼
                                              PrinterModule  ◀── you implement this
                                                   │  encode → send → detect completion
                                                   ▼  job.progress(.counter/.printing/.done)
                                              printer (USB / TCP / …)
```

**What crosses the boundary, each way:**

| Engine → driver (in `DriverJob`)            | Driver → engine                     |
| ------------------------------------------- | ----------------------------------- |
| `pages` — the label content (+ cut, isLast) | `progress(.counter(done, of))`      |
| `singleLabel` — the chosen send method      | `progress(.printing)` (coarse)      |
| `isCancelled` — a flag to poll              | `progress(.done)`                   |
| `connection`, `status`, `estLabelMs`        | (throws on failure)                 |

The engine has **zero** PICL / USB / pacing / subscription logic. Grep proves it: a search
for those terms in `EngineKit/` and `Engine/` comes back empty. All of it lives in the driver.

---

## 2. Data structures (the contract types)

All defined in `MacApp/Sources/Core/Printing/`. These are the types you must produce/consume.

### `PrinterDevice` — what `enumerate()` returns
```swift
public struct PrinterDevice: Identifiable, Hashable {
    public let id: String          // "<vid>:<pid>:<serial>" (USB) or "net:<serial>" (network)
    public let name: String        // human label, e.g. "M611"
    public let model: String       // "M610" | "M611" — MUST match capabilities.model
    public let serial: String
    public var status: Status      // .ready | .busy | .offline
    public var host: String?       // IP/host for network printers; nil for USB
}
```
`model` is the routing key. `printSettings(forName:)` and the registry both look the device up
by this exact string, so `enumerate()` must set `model` to your `capabilities.model`.

### `PrinterCapabilities` — what your driver declares (static)
```swift
public struct PrinterCapabilities {
    public let model: String                       // "M611"
    public let supportedTransports: Set<PrinterTransport>   // .usb / .network / .bluetooth
    public let hasLiveTelemetry: Bool              // live ribbon/label/battery over the wire?
    public let hasAutoCutter: Bool = false         // built-in cutter the Engine can actuate?
    public let ribbonLengthInches: Double = 0      // full-ribbon length for the supply forecast (0 = none)
    public let sendMode: SendModeSupport = .selectable(defaultSingle: false)
}

public enum SendModeSupport: Equatable {
    case fixed                            // driver always reports good progress → UI greys the toggle
    case selectable(defaultSingle: Bool)  // user picks one-at-a-time vs full job
}
```
The Engine drives a printer only over a transport that is **both** in `supportedTransports`
**and** enabled by the user per-printer. `sendMode` decides whether the per-printer UI offers
the one-at-a-time/full-job choice (`.selectable`) or hides it because the driver always reports
good progress on its own (`.fixed`).

### `RenderedLabel` — the label content (printer-agnostic raster)
```swift
public struct RenderedLabel: Codable, Equatable {
    public var pixels: Data    // row-major, 1 byte/pixel, 0xFF = ink, 0x00 = white
    public var width: Int
    public var height: Int
    public var partNumber: String   // loaded supply part #, "" if unknown
}
```
The front-end renders to this; **your `encode()` turns it into your printer's wire format.**

### `CutMode` — per-page cut intent (`Core/IPC/PrintJobFile.swift`)
```swift
public enum CutMode: String, Codable {
    case afterJobLast   // one cut at the end of the whole job
    case eachLabel      // cut after every label (needed for continuous stock)
    case never          // no cut (e.g. pre-cut die-cut labels)
}
```
The Engine resolves the right cut per page and puts it on each `DriverPage` (see below); your
encoder just honors `page.cut` + `page.isLast`.

### `CassetteStatus` — what `readStatus()` returns (`Core/IPC/PrinterStatusFile.swift`)
The loaded media + printer telemetry. Key fields: `partNumber`, label/printable dimensions
(mils + pixels), `isDieCut` / `isContinuous`, `supplyRemainingPct`, `ribbonRemainingPct`,
`batteryPct`, `acConnected`, `areaRotation`, pre-flight flags (`printheadOpen`,
`substrateInvalid`, `ribbonInvalid`), `printerSerial`, `firmwareVersion`. Return `nil` if you
can't read it. Populate only what your printer exposes; the rest are optionals.

### `PrinterConnection` — your opaque connection token
```swift
public protocol PrinterConnection: AnyObject {}
```
The Engine holds it as an existential and hands it back to you; it never inspects the concrete
type. Wrap whatever you need (a socket fd, a libusb handle, the host string, …):
```swift
final class TCPConnection: PrinterConnection { let fd: Int32; let host: String; … }
```

### `DriverPage`, `DriverJob`, `JobProgress` — the `run()` contract
```swift
public struct DriverPage {
    public let label: RenderedLabel
    public let cut: CutMode      // resolved by the Engine for THIS page
    public let isLast: Bool      // last page of the job (place an end-of-job cut here)
}

public struct DriverJob {
    public let pages: [DriverPage]
    public let status: CassetteStatus?     // last-known media (for rotation / part #)
    public let singleLabel: Bool           // user's send choice (ignored if sendMode == .fixed)
    public let estLabelMs: Int             // per-label time estimate — a PACING FALLBACK only
    public let connection: PrinterConnection
    public let isCancelled: () -> Bool     // poll this; stop sending when true
    public let progress: (JobProgress) -> Void
}

public enum JobProgress {
    case counter(done: Int, of: Int)   // per-label progress → menu shows "done of N"
    case printing                      // coarse → menu shows "Printing…"
    case done                          // job finished → bar fills to 100% (unless cancelled)
}
```
The Engine **builds** the pages (it prepends a feed-to-clear blank lead if requested, resolves
each page's cut, flags the last page). You only decide **how** to send them and what progress
to report.

---

## 3. The `PrinterModule` protocol — what you implement

```swift
public protocol PrinterModule: AnyObject {
    var capabilities: PrinterCapabilities { get }

    func handles(model: String) -> Bool                         // default: model == capabilities.model
    func enumerate() -> [PrinterDevice]                         // discover connected printers
    func encode(label:status:cut:isLastLabel:) -> [UInt8]       // raster → wire bytes
    func open(_ device: PrinterDevice) throws -> PrinterConnection
    func send(_ bytes: [UInt8], on: PrinterConnection) throws   // write one label's bytes
    func close(_ connection: PrinterConnection)
    func readStatus(_ device: PrinterDevice) -> CassetteStatus? // media/telemetry, or nil
    func labelsRemaining(on: PrinterConnection) -> Int          // default: -1 (no counter)
    func run(_ job: DriverJob) throws                           // the heart — see §5
    func reportsCounter(singleLabel: Bool) -> Bool              // default: false
}
```
Defaults (in a protocol extension): `handles` matches on `capabilities.model`,
`labelsRemaining` returns `-1`, `reportsCounter` returns `false`. Override what you need.

`reportsCounter(singleLabel:)` tells the Engine **up front** whether this job will report a
real per-label `.counter` (so it shows a progress bar) or only coarse `.printing`. Return
`true` for a mode where you can detect per-label completion; `false` for a fire-and-forget
batch.

---

## 4. How the Engine drives you (the call path)

`PrinterManager.submit(...)` (`MacApp/Sources/EngineKit/PrinterManager.swift`) does, per job:

1. Resolve the device + your module (via the registry, by `device.model`) + the per-printer
   `PrintSettings` (just `singleLabelPrinting` now — there is **no inter-label delay**;
   printing always runs at full speed).
2. Compute `singleLabel`: `if case .selectable = capabilities.sendMode { settings.singleLabelPrinting } else { false }`.
3. Pre-flight: for telemetry-capable drivers it re-reads `readStatus` and blocks the job if a
   printhead-open / invalid-supply / invalid-ribbon flag is set.
4. On the **per-printer serial device queue** (so your `run` may block freely): `open(device)`,
   build `[DriverPage]`, then:
```swift
try module.run(DriverJob(
    pages: pages, status: liveStatus, singleLabel: singleLabel,
    estLabelMs: max(150, estLabelMs), connection: conn,
    isCancelled: { job.isCancelled },
    progress: { upd in Task { @MainActor in
        switch upd {
        case .counter(let done, _): if done > job.completedLabels { job.completedLabels = done }
        case .printing: break
        case .done: if !job.isCancelled { job.completedLabels = pages.count }  // 100% only on a clean finish
        }
    }}))
// defer { module.close(conn) }   ← fires when run() returns OR throws
```
Note the consequences baked into this:
- **Progress is monotonic.** `.counter(done:)` only ever moves the bar forward.
- **`.done` fills to 100% only if not cancelled** — so a cancelled job keeps the partial count
  it actually printed (Recent Prints shows the truth). In single-label modes you often don't
  emit `.done` at all and just report the final `.counter`.
- **`close()` runs the instant `run()` returns or throws.** Therefore **`run()` must not return
  until in-flight printing is safe to abandon** (see §5, the drain rule).

The user changes the per-printer mode under **Per-Printer Settings**; the editor commits a draft
with **Apply** (`PrinterModelStore.replace`). Cancel is the menu's Cancel button →
`job.requestCancel()` → the `isCancelled` flag your `run` polls.

---

## 5. Implementing `run()` — the heart

`run()` has three jobs: **encode**, **send (your strategy)**, and **report progress** — and
one hard rule.

**The drain rule (critical):** the Engine closes the connection the moment `run()` returns
(and on throw). If you return while the printer still has un-printed bytes you streamed, you
can abort a label mid-print (the M611 gets stuck "waiting"). So **before returning, wait until
the labels you've sent are safely committed** — either confirmed printed, or drained for a
bounded time. Put the drain in a `defer` if you want it to cover the throw path too.

**Cancel:** the printer almost certainly has **no mid-print cancel command** (the M611 has
none). So cancel = *stop sending the next label*; whatever you already sent finishes. To make
cancel responsive, **don't pipeline far ahead** — keep only ~1 label queued beyond the one
printing (see the M611 "halfway" pattern below).

**Completion detection is the hard part** — there is rarely a single clean signal. Two proven
patterns, by what the printer exposes:

### Pattern A — hardware counter (the M610)
The M610 exposes a SmartCell **labels-remaining** counter you can read between sends
(`labelsRemaining(on:)`). Single-label `run()`:
```
read initialRemaining
for each page:
    send(page); poll the counter until it drops by (i+1)  // this label printed
    progress(.counter(done: i+1, of: count))
settle on the counter until it drops by `count` (bounded), then progress(.done)
```
`reportsCounter → true` (both modes). Track the *lowest* remaining seen so a roll-change blip
can't make the delta go negative.

### Pattern B — status subscription / pushes (the M611)
The M611 sends **no** per-job ack on the print channel and a *targeted* job-status get returns
"Invalid Value". The only live signal is its PICL status: send
`SubscribeAllCurrentAndNewProperties` **once** on the status channel (TCP 9102, or USB vendor
iface 1), then the printer **pushes** small frames as each job goes
`"" → Streaming → Printing → Print Complete`. So:
```
open a PERSISTENT subscription, drain the initial snapshot into a running map
for each label: build a UNIQUE job id; the printer echoes it as the job's ExternalId
loop:
    send the next label when nothing is printing, or the current is ~HALFWAY done
       (measured against the REAL per-label time, calibrated from the pushes)  ← no idle, but ≤~2 in flight
    read a push, merge it, recount completed labels (match by our unique id)
    progress(.counter(done: completed, of: count))
    stop when (all sent or cancelled) AND all sent labels are confirmed printed
progress(.done)   // clean finish only
```
Both USB (`M611USB.openSubscription`/`readSubFrame`) and network (TCP 9102 + `readFrame`) use
the identical logic; only the transport read differs. Fall back to the `estLabelMs` time
estimate if the subscription can't open. Confirmed on hardware over both transports.

### Full-job mode
For `singleLabel == false`, send everything as one job/batch as fast as possible and report
`.printing` then `.done` (coarse), or a counter if you can. `reportsCounter(singleLabel: false)`
should return `false` unless you can track a batch. The M611 builds one multi-page job
(continuous feed, one end-of-job cut) and holds "Printing…" until the printer reports complete.

---

## 6. Step-by-step: add a driver

1. **Create a module target** `MacApp/Sources/PrinterXXX/` and add it to `Package.swift`
   (a library product + dependency from `EngineKit`). Keep transport code (libusb / sockets)
   inside this module — front-ends must not link it.
2. **Implement `PrinterModule`** in `XXXModule.swift`:
   - `capabilities` (model id, transports, telemetry/cutter/ribbon, `sendMode`).
   - `enumerate()` → `PrinterDevice`s with `model == capabilities.model`.
   - `encode()` → your wire format from a `RenderedLabel` (honor `cut` + `isLastLabel`).
   - `open` / `send` / `close` over your transport, returning a `PrinterConnection` subclass.
   - `readStatus()` → `CassetteStatus` (as much as the printer exposes; `nil` if none).
   - `labelsRemaining()` if you have a hardware counter (else inherit `-1`).
   - `reportsCounter(singleLabel:)` — `true` where you can detect per-label completion.
   - `run(_:)` — §5: encode → send strategy → progress, **obey the drain + cancel rules**.
3. **Register it** in `PrinterManager.init` next to the others:
   ```swift
   PrinterModuleRegistry.shared.register(XXXModule())
   ```
4. **Seed defaults** in `PrinterModelList.makeDefault()` / `migrated()`
   (`Core/PrinterModels.swift`) so the per-printer settings + supply catalog know the model.
5. **`swift build && swift test`.** Add unit tests for the offline-testable parts (wire-format
   framing, status parsing) — see `MacApp/Tests/M611BitmapTests.swift` / `M611PICLTests.swift`.

The Engine, menu UI, queue, pre-flight, supply forecast, and Recent Prints all work
automatically once the module is registered and reports through the contract — **no engine
changes.**

---

## 7. Rules & gotchas (learned the hard way)

- **Always print at full speed.** There is no inter-label delay setting.
- **The driver owns send strategy + completion; the Engine owns lifecycle + UI.** Never put
  printer-specific logic in `EngineKit`/`Engine`.
- **`run()` must drain before returning** — the Engine closes the connection on return/throw.
- **Cancel = stop sending**, because printers typically have no mid-print cancel. Limit how far
  you pipeline ahead so cancel is responsive (the M611 keeps ≤~2 labels in flight).
- **Don't trust the static time estimate for completion** — `estLabelMs` is a *fallback* and was
  ~4× too fast for the M611. Detect real completion when you can; calibrate timing from the
  printer if you must pace by time.
- **Give each job a UNIQUE id** if you match status by id, so a poll never matches a prior
  completed job of the same id still in the printer's slot ring.
- **Bound your network/USB I/O.** Use non-blocking connects with a timeout and read full framed
  responses (length-prefix), or a stalled port hangs the per-printer serial queue. Set
  `SO_NOSIGPIPE` on sockets (and the Engine ignores `SIGPIPE`) so a printer-closed socket throws
  instead of killing the process.
- **`run()` executes on a per-printer serial queue** — blocking is fine and expected; progress
  closures hop to `@MainActor` themselves.

---

## 8. Reference implementations

- `MacApp/Sources/PrinterM610/M610Module.swift` — VGL over USB, **hardware counter** completion
  (Pattern A). `BradyUSB.swift` is its transport.
- `MacApp/Sources/PrinterM611/M611Module.swift` — 1-bpp bitmap over USB **and** network,
  **status-subscription** completion (Pattern B). `M611Bitmap.swift` (encode),
  `M611PICL.swift` (status protocol), `M611USB.swift` (USB transport).

Read those two — between them they cover both completion patterns, both transports, full-job vs
single-label, cut handling, and pre-flight telemetry.
