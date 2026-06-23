import Foundation
import JavaScriptCore
import CoreGraphics

// MARK: – Barcode generation for the print path
//
// Renders any bwip-js symbology (QR, DataMatrix, Code 128/39/93, PDF417, Aztec,
// EAN/UPC, ITF, Codabar, …) by running the vendored bwip-js engine in JavaScriptCore
// and rasterizing its RAW module data crisply at the target size — so a field-bound
// barcode is regenerated per record at print time, at full print DPI, with no fixed-
// resolution bitmap. The designer/print-window previews use the same bwip-js (in their
// WKWebView), so preview and print agree.
//
// Invalid or empty input throws inside bwip-js; we surface that as nil so the caller
// prints the label blank (the chosen empty/invalid policy) rather than a garbage code.

public final class BarcodeRenderer {

    public static let shared = BarcodeRenderer()

    private let ctx: JSContext?
    private let lock = NSLock()
    private var ready = false

    private init() {
        ctx = JSContext()
        ctx?.exceptionHandler = { _, _ in }   // encode errors are reported via the JS return value
        guard let ctx = ctx,
              let url = CoreResources.url("bwip-js", "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else { return }
        // bwip-js decodes its embedded fonts with atob(); bare JavaScriptCore has no
        // atob/btoa, so provide them natively before loading the engine.
        let atob: @convention(block) (String) -> String = { b64 in
            guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return "" }
            var s = ""; s.unicodeScalars.reserveCapacity(d.count)
            for b in d { s.unicodeScalars.append(UnicodeScalar(b)) }
            return s
        }
        let btoa: @convention(block) (String) -> String = { s in
            Data(s.unicodeScalars.map { UInt8($0.value & 0xff) }).base64EncodedString()
        }
        ctx.setObject(atob, forKeyedSubscript: "atob" as NSString)
        ctx.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        ctx.evaluateScript("var module={exports:{}};")
        ctx.evaluateScript(src)
        // Normalize bwip-js raw() output into one shape: a row-major dark-module grid.
        // 2D symbols expose `pixs` (pixx×pixy 0/1 matrix); 1D expose `sbs` (alternating
        // bar/space module widths, starting with a bar) which we expand into one row.
        ctx.evaluateScript(#"""
        var bwipjs = module.exports;
        function __vlBarcode(bcid, text, eclevel) {
          try {
            var opts = { bcid: String(bcid), text: String(text) };
            if (eclevel) opts.eclevel = String(eclevel);
            var s = bwipjs.raw(opts)[0];
            if (s.pixs) { return { ok:true, w:s.pixx, h:s.pixy, bits:s.pixs }; }
            if (s.sbs)  {
              var row = [], dark = true;
              for (var i = 0; i < s.sbs.length; i++) {
                var wd = s.sbs[i] | 0;
                for (var k = 0; k < wd; k++) row.push(dark ? 1 : 0);
                dark = !dark;
              }
              return { ok:true, w:row.length, h:1, bits:row };
            }
            return { ok:false };
          } catch (e) { return { ok:false }; }
        }
        """#)
        ready = ctx.objectForKeyedSubscript("__vlBarcode") != nil
    }

    /// A decoded barcode as a row-major dark-module grid. `h == 1` for 1-D symbols.
    public struct Symbol { public var w: Int; public var h: Int; public var bits: [Bool] }

    /// Encode `text` as `bcid`. Returns nil when the input is empty or can't be encoded
    /// by the symbology (e.g. letters in an EAN-13) — the caller then prints blank.
    public func symbol(bcid: String, text: String, eclevel: String?) -> Symbol? {
        guard ready, let ctx = ctx, !text.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let fn = ctx.objectForKeyedSubscript("__vlBarcode"),
              let res = fn.call(withArguments: [bcid, text, eclevel ?? ""]),
              res.isObject, res.objectForKeyedSubscript("ok").toBool() else { return nil }
        let w = Int(res.objectForKeyedSubscript("w").toInt32())
        let h = Int(res.objectForKeyedSubscript("h").toInt32())
        guard w > 0, h > 0, w * h <= 4_000_000,
              let arr = res.objectForKeyedSubscript("bits").toArray() as? [NSNumber],
              arr.count == w * h else { return nil }
        return Symbol(w: w, h: h, bits: arr.map { $0.intValue != 0 })
    }

    /// True if `bcid`/`text` encodes — used by the UI to flag a bad record without
    /// drawing anything.
    public func canEncode(bcid: String, text: String, eclevel: String?) -> Bool {
        symbol(bcid: bcid, text: text, eclevel: eclevel) != nil
    }

    /// Draw `text` as a barcode filling `rect` (in the given CG context's current user
    /// space). Modules are drawn aliased for crisp edges; a quiet zone is included so the
    /// code scans even when placed against other content. 2-D codes preserve their square
    /// aspect (centered); 1-D codes stretch to the box height. Returns false if nothing
    /// was drawn (invalid/empty input) so the caller can leave the label blank.
    @discardableResult
    public func draw(bcid: String, text: String, eclevel: String?,
                     in rect: CGRect, ctx cg: CGContext, quietModules: Int = -1) -> Bool {
        guard rect.width > 0, rect.height > 0,
              let sym = symbol(bcid: bcid, text: text, eclevel: eclevel) else { return false }
        let is2D = sym.h > 1
        let quiet = quietModules >= 0 ? quietModules : (is2D ? 2 : 10)
        let gridW = sym.w + quiet * 2
        let gridH = is2D ? (sym.h + quiet * 2) : sym.h   // 1-D: bars fill the box height

        cg.saveGState()
        cg.setShouldAntialias(false)
        cg.setFillColor(gray: 0, alpha: 1)

        if is2D {
            // Square modules, fit-and-center, integer module size for crispness.
            let m = max(1.0, floor(min(rect.width / CGFloat(gridW), rect.height / CGFloat(gridH))))
            let drawW = m * CGFloat(gridW), drawH = m * CGFloat(gridH)
            let ox = rect.minX + (rect.width - drawW) / 2 + m * CGFloat(quiet)
            let oy = rect.minY + (rect.height - drawH) / 2 + m * CGFloat(quiet)
            for row in 0..<sym.h {
                // pixs row 0 is the TOP of the symbol; CG user space here is y-up, so flip.
                let y = oy + CGFloat(sym.h - 1 - row) * m
                var col = 0
                while col < sym.w {
                    if sym.bits[row * sym.w + col] {
                        var run = 1
                        while col + run < sym.w, sym.bits[row * sym.w + col + run] { run += 1 }
                        cg.fill(CGRect(x: ox + CGFloat(col) * m, y: y, width: m * CGFloat(run), height: m))
                        col += run
                    } else { col += 1 }
                }
            }
        } else {
            // 1-D: module width fills the box (incl. horizontal quiet); bars span height.
            let mW = rect.width / CGFloat(gridW)
            let ox = rect.minX + mW * CGFloat(quiet)
            var col = 0
            while col < sym.w {
                if sym.bits[col] {
                    var run = 1
                    while col + run < sym.w, sym.bits[col + run] { run += 1 }
                    cg.fill(CGRect(x: ox + CGFloat(col) * mW, y: rect.minY,
                                   width: mW * CGFloat(run), height: rect.height))
                    col += run
                } else { col += 1 }
            }
        }
        cg.restoreGState()
        return true
    }
}
