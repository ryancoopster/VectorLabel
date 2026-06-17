import Foundation
import CoreGraphics
import CoreText
import AppKit

// WireRecord is defined in ExportWatcher.swift.
// VLTemplate and TemplateObject are defined in TemplateStore.swift.
// This file contains only the renderer.

// MARK: – Brady label geometry

extension BradyLabelSize {
    /// Printable area in inches, from the catalog (BradyCatalog.json). For
    /// BM-33-427 the printable zone is 1.5×1.5 even though the total label is
    /// 1.5×4.0. Unknown part numbers fall back to the physical size.
    public var printableWidthInches: Double {
        BradyCatalog.printableWidthInches(forPartNumber: partNumber) ?? widthInches
    }

    public var printableHeightInches: Double {
        BradyCatalog.printableHeightInches(forPartNumber: partNumber) ?? heightInches
    }

    public var printablePixelWidth:  Int { Int((printableWidthInches  * Double(dpi)).rounded()) }
    public var printablePixelHeight: Int { Int((printableHeightInches * Double(dpi)).rounded()) }
}

// MARK: – Renderer

/// Renders a VLTemplate + WireRecord to a 1-byte-per-pixel mono buffer
/// (0xFF = ink/black, 0x00 = white) suitable for BradyVGL.buildPrintJob.
public enum LabelRenderer {

    /// SC is the coordinate scale used by the HTML designer: 185 px per inch-unit.
    /// Template object coordinates are in 0…1 relative to the printable area.
    /// We map those onto the actual print DPI here.
    /// `offset` shifts all drawn content by (dx, dy) printer pixels — the
    /// per-printer calibration offset. dx is along the label width, dy along
    /// the label height (same sense as the designer's x/y).
    public static func render(template: VLTemplate, record: WireRecord,
                       offset: (dx: Double, dy: Double) = (0, 0)) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let size = template.labelSize else { return nil }
        let dpi = size.dpi
        let pw  = size.printablePixelWidth
        // Continuous supplies have no fixed height — the printable height is the
        // user-chosen label length (effectivePrintableHeightInches); die-cut
        // supplies keep the catalog's fixed printable height.
        let phInches = template.effectivePrintableHeightInches ?? size.printableHeightInches
        let ph  = max(1, Int((phInches * Double(dpi)).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph,
            bitsPerComponent: 8, bytesPerRow: pw,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // White background
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // Flip so (0,0) is top-left (matches HTML canvas convention)
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: 1, y: -1)

        // Some supplies (e.g. the 33-427 / BM-109-427) feed rotated relative to
        // the designer layout, so the whole label is rotated to match. The angle
        // comes from the catalog (feedRotationDeg); its printable area is square,
        // so a 90° rotation stays in bounds.
        let feedRotation = BradyCatalog.feedRotationDeg(forPartNumber: size.partNumber)
        if abs(feedRotation) > 0.0001 {
            let cx = CGFloat(pw) / 2, cy = CGFloat(ph) / 2
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: CGFloat(feedRotation) * .pi / 180)   // clockwise in this y-down space
            ctx.translateBy(x: -cx, y: -cy)
        }

        // Custom Designer landscape canvas (continuous only): the user authored the
        // design rotated 90° (length horizontal), so rotate the raster to match. The
        // context stays the physical width×length; this maps the length×width design
        // onto it. NOTE: orientation/handedness is set here — verify with a test
        // print on real tape before production use. #14.
        if (template.canvasRot ?? 0) == 90 {
            ctx.translateBy(x: CGFloat(pw), y: 0)
            ctx.rotate(by: .pi / 2)
        }

        // Per-printer calibration shift (in top-left pixel space).
        ctx.translateBy(x: CGFloat(offset.dx), y: CGFloat(offset.dy))

        for obj in template.objs {
            // Rotation is clockwise about the object's center, matching the
            // designer's CSS `transform:rotate(deg)`. User space is y-down here
            // (we flipped above), so a positive CG rotation is clockwise too.
            let rotDeg = obj.rot ?? 0
            let rotated = abs(rotDeg) > 0.0001
            if rotated {
                let c = rect(for: obj, dpi: dpi)
                ctx.saveGState()
                ctx.translateBy(x: c.midX, y: c.midY)
                ctx.rotate(by: CGFloat(rotDeg * .pi / 180.0))
                ctx.translateBy(x: -c.midX, y: -c.midY)
            }
            switch obj.t {
            case "tx": drawText(obj, record: record, in: ctx, dpi: dpi)
            case "ln": drawLine(obj, in: ctx, dpi: dpi)
            case "rc": drawRect(obj, in: ctx, dpi: dpi)
            case "ci", "ov": drawEllipse(obj, in: ctx, dpi: dpi)
            case "ar": drawArrow(obj, in: ctx, dpi: dpi)
            case "im", "sy": drawImage(obj, in: ctx, dpi: dpi)
            default: break
            }
            if rotated { ctx.restoreGState() }
        }

        guard let data = ctx.data else { return nil }
        let raw = data.bindMemory(to: UInt8.self, capacity: pw * ph)
        var pixels = [UInt8](repeating: 0, count: pw * ph)
        for i in 0 ..< (pw * ph) {
            pixels[i] = raw[i] < 0x80 ? 0xFF : 0x00
        }
        return (pixels, pw, ph)
    }

    // MARK: – Drawing helpers

    /// The HTML designer treats object coordinates as inches (it renders at
    /// SC = 185 px per inch via `o.x * SC`), NOT as a 0…1 fraction of the
    /// printable area. So map inches → print pixels with the print DPI, which
    /// reproduces the authored layout at any printable size.
    private static func rect(for obj: TemplateObject, dpi: Int) -> CGRect {
        let s = Double(dpi)
        return CGRect(
            x: obj.x * s,
            y: obj.y * s,
            width:  obj.w * s,
            height: obj.h * s
        )
    }

    /// Designer renders at 185 px/inch; print is `dpi` px/inch. To keep the same
    /// physical size, every pixel measurement scales by `dpi / 185`.
    private static let designerDPI = 185.0

    private static func drawText(_ obj: TemplateObject, record: WireRecord, in ctx: CGContext, dpi: Int) {
        // Resolve the displayed string from the text mode. Legacy objects have
        // only `f`, so a nil mode with a formula → formula.
        let mode = obj.mode ?? (obj.field != nil ? "field"
                                : (obj.text != nil && (obj.f?.isEmpty ?? true) ? "static" : "formula"))
        let text: String
        switch mode {
        case "static": text = obj.text ?? ""
        case "field":  text = obj.field.flatMap { record.fields[$0] } ?? ""
        default:       text = FormulaEngine.evaluate(obj.f ?? "", fields: record.fields)
        }
        guard !text.isEmpty else { return }

        let r = rect(for: obj, dpi: dpi)

        // Font
        let fontName: String
        switch obj.font ?? "Helvetica Neue" {
        case "Arial Narrow": fontName = "ArialNarrow"
        case "Courier New":  fontName = "CourierNewPSMT"
        case "Georgia":      fontName = "Georgia"
        case "Impact":       fontName = "Impact"
        case "Tahoma":       fontName = "Tahoma"
        case "Verdana":      fontName = "Verdana"
        default:             fontName = "HelveticaNeue"
        }

        // The HTML designer renders text at:  fz = max(7, obj.fs * 185/100) px
        // (185 px per inch). Reproduce that exact physical size at print DPI by
        // computing the designer pixel size, then scaling by dpi/185.
        let designerPx = max(7.0, (obj.fs ?? 14.0) * designerDPI / 100.0)
        var fontSize   = designerPx * (Double(dpi) / designerDPI)

        var traits: NSFontTraitMask = []
        if obj.bold   == true { traits.insert(.boldFontMask) }
        if obj.italic == true { traits.insert(.italicFontMask) }

        let fontManager = NSFontManager.shared
        func makeFont(_ size: Double) -> NSFont {
            if let base = NSFont(name: fontName, size: CGFloat(size)) {
                return traits.isEmpty ? base : fontManager.convert(base, toHaveTrait: traits)
            }
            return NSFont.systemFont(ofSize: CGFloat(size), weight: obj.bold == true ? .bold : .regular)
        }

        let stretchFactor = (obj.stretch ?? 100.0) / 100.0
        let kern: CGFloat? = (obj.tracking.map { $0 != 0 ? CGFloat($0) * CGFloat(Double(dpi) / designerDPI) : nil } ?? nil)

        // Auto-scale: `fs` is the maximum; shrink the font so the single line fits
        // the box width (never grows it). Only for non-wrapped text.
        if obj.autoScale == true && obj.wrapText != true {
            var mattrs: [NSAttributedString.Key: Any] = [.font: makeFont(fontSize)]
            if let kern = kern { mattrs[.kern] = kern }
            let mstr = NSAttributedString(string: text, attributes: mattrs)
            let mfs = CTFramesetterCreateWithAttributedString(mstr)
            let natural = CTFramesetterSuggestFrameSizeWithConstraints(
                mfs, CFRange(location: 0, length: 0), nil,
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), nil)
            let effWidth = natural.width * CGFloat(stretchFactor)
            if effWidth > r.width && effWidth > 0 {
                fontSize = max(1.0, fontSize * Double(r.width / effWidth))
            }
        }

        let nsFont = makeFont(fontSize)
        let ctFont = CTFontCreateWithName(nsFont.fontName as CFString, CGFloat(fontSize), nil)

        let paraStyle = NSMutableParagraphStyle()
        switch obj.al ?? "left" {
        case "center":  paraStyle.alignment = .center
        case "right":   paraStyle.alignment = .right
        case "justify": paraStyle.alignment = .justified
        default:        paraStyle.alignment = .left
        }
        if obj.wrapText != true { paraStyle.lineBreakMode = .byClipping }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .paragraphStyle: paraStyle,
            .foregroundColor: CGColor(gray: 0.0, alpha: 1.0)
        ]
        if obj.underline == true {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let tracking = obj.tracking, tracking != 0 {
            // Designer letter-spacing is in screen px; scale to print px.
            attrs[.kern] = CGFloat(tracking) * CGFloat(Double(dpi) / designerDPI)
        }

        let attrStr = NSAttributedString(string: text, attributes: attrs)

        // Vertical alignment
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: r.width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )

        var drawRect = r
        switch obj.valign ?? "middle" {
        case "top":
            drawRect.origin.y = r.minY
        case "bottom":
            drawRect.origin.y = r.maxY - suggestedSize.height
        default: // middle
            drawRect.origin.y = r.midY - suggestedSize.height / 2
        }
        drawRect.size.height = max(r.height, suggestedSize.height)

        // The context is globally y-flipped so rects/lines use a top-left origin,
        // but CTFrameDraw respects that flip and would render text upside-down
        // (the cause of "scrambled"/mirrored printed text). Counter the flip
        // around this text block's vertical center so glyphs stay upright while
        // keeping the top-left positioning.
        let stretch = (obj.stretch ?? 100.0) / 100.0
        ctx.saveGState()
        ctx.translateBy(x: 0, y: drawRect.midY * 2)
        ctx.scaleBy(x: 1, y: -1)
        if abs(stretch - 1.0) > 0.01 {
            // Horizontal stretch around the block's left edge.
            ctx.translateBy(x: drawRect.origin.x, y: 0)
            ctx.scaleBy(x: CGFloat(stretch), y: 1.0)
            ctx.translateBy(x: -drawRect.origin.x, y: 0)
        }
        let path = CGPath(rect: drawRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private static func drawLine(_ obj: TemplateObject, in ctx: CGContext, dpi: Int) {
        let s  = Double(dpi)
        let x1 = obj.x * s
        let y  = obj.y * s
        let x2 = (obj.x + obj.w) * s
        // Line weight is in designer screen px; scale to print px (floor at 1px).
        let lw = max(1.0, (obj.lw ?? 1.0) * s / designerDPI)

        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setLineWidth(CGFloat(lw))
        ctx.move(to: CGPoint(x: x1, y: y))
        ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
    }

    private static func drawRect(_ obj: TemplateObject, in ctx: CGContext, dpi: Int) {
        let r  = rect(for: obj, dpi: dpi)
        let lw = max(1.0, (obj.lw ?? 1.0) * Double(dpi) / designerDPI)
        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setLineWidth(CGFloat(lw))
        ctx.stroke(r)
    }

    /// Circle ("ci") and oval ("ov") — both stroke an ellipse in the object's
    /// box (a circle is just an oval with equal width/height).
    private static func drawEllipse(_ obj: TemplateObject, in ctx: CGContext, dpi: Int) {
        let r  = rect(for: obj, dpi: dpi)
        let lw = max(1.0, (obj.lw ?? 1.0) * Double(dpi) / designerDPI)
        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setLineWidth(CGFloat(lw))
        ctx.strokeEllipse(in: r)
    }

    /// Image ("im") — the embedded monochrome PNG (data URL in obj.src), drawn
    /// into the object's box. The image is already black/white with alpha, so
    /// the final 1-bit threshold leaves it crisp and transparent areas read as
    /// white (no ink).
    private static func drawImage(_ obj: TemplateObject, in ctx: CGContext, dpi: Int) {
        guard let src = obj.src,
              let comma = src.firstIndex(of: ","),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...])),
              let cg = NSBitmapImageRep(data: data)?.cgImage
        else { return }
        let r = rect(for: obj, dpi: dpi)
        ctx.saveGState()
        // CG draws images bottom-up; flip locally so it lands upright in our
        // already-flipped (top-left origin) context.
        ctx.translateBy(x: r.minX, y: r.minY + r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// Arrow ("ar") — a horizontal shaft along the object's centerline (obj.y),
    /// with filled triangular heads at either/both ends. Thickness and head
    /// size are designer px scaled to the print DPI, matching the HTML render.
    private static func drawArrow(_ obj: TemplateObject, in ctx: CGContext, dpi: Int) {
        let s   = Double(dpi)
        let scale = s / designerDPI
        let xL  = obj.x * s
        let xR  = (obj.x + obj.w) * s
        let yc  = obj.y * s
        let th  = max(1.0, (obj.lw ?? 2.0) * scale)
        let head = max(4.0, (obj.arrowSize ?? 12.0) * scale)
        let hw  = head * 0.6
        let startHead = obj.arrowStart ?? false
        let endHead   = obj.arrowEnd ?? true

        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setFillColor(gray: 0.0, alpha: 1.0)

        // Shaft (inset where a head sits so the line doesn't poke through it).
        let x1 = xL + (startHead ? head : 0)
        let x2 = xR - (endHead ? head : 0)
        if x2 > x1 {
            ctx.setLineWidth(CGFloat(th))
            ctx.move(to: CGPoint(x: x1, y: yc))
            ctx.addLine(to: CGPoint(x: x2, y: yc))
            ctx.strokePath()
        }
        if endHead {
            ctx.move(to: CGPoint(x: xR, y: yc))
            ctx.addLine(to: CGPoint(x: xR - head, y: yc - hw))
            ctx.addLine(to: CGPoint(x: xR - head, y: yc + hw))
            ctx.closePath(); ctx.fillPath()
        }
        if startHead {
            ctx.move(to: CGPoint(x: xL, y: yc))
            ctx.addLine(to: CGPoint(x: xL + head, y: yc - hw))
            ctx.addLine(to: CGPoint(x: xL + head, y: yc + hw))
            ctx.closePath(); ctx.fillPath()
        }
    }

    // MARK: – Calibration grid

    /// Render a calibration target for the given label: a 1px grid at 1/8"
    /// spacing, a border inset 1/16" from each printable edge (so there's an
    /// even margin all round to judge centering), heavier lines every 1", and
    /// a solid 1/8" square marking the origin corner (so feed direction /
    /// mirroring is obvious). The per-printer `offset` is applied so reprinting
    /// after a tweak shows the shift.
    public static func renderCalibrationGrid(size: BradyLabelSize,
                                      offset: (dx: Double, dy: Double) = (0, 0))
        -> (pixels: [UInt8], width: Int, height: Int)? {
        let pw  = size.printablePixelWidth
        let ph  = size.printablePixelHeight
        let dpi = Double(size.dpi)
        guard pw > 0, ph > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph,
            bitsPerComponent: 8, bytesPerRow: pw,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(offset.dx), y: CGFloat(offset.dy))
        ctx.setFillColor(gray: 0.0, alpha: 1.0)

        let step  = dpi / 8.0          // 1/8" grid
        let inset = dpi / 16.0         // 1/16" margin inside each printable edge
        let x0 = inset, y0 = inset
        let x1 = Double(pw) - inset, y1 = Double(ph) - inset
        // Lines are clipped to the inset rectangle [x0,x1] × [y0,y1].
        func vline(_ x: Double, _ w: Double) { ctx.fill(CGRect(x: x, y: y0, width: w, height: y1 - y0)) }
        func hline(_ y: Double, _ h: Double) { ctx.fill(CGRect(x: x0, y: y, width: x1 - x0, height: h)) }

        // 1/8" grid (1px), with every 8th line (= 1") drawn at 3px, starting
        // from the inset origin.
        var i = 0
        var x = x0
        while x <= x1 + 0.5 { vline(x.rounded(), (i % 8 == 0) ? 3 : 1); x += step; i += 1 }
        i = 0
        var y = y0
        while y <= y1 + 0.5 { hline(y.rounded(), (i % 8 == 0) ? 3 : 1); y += step; i += 1 }

        // Border inset 1/16" from the printable bounds.
        vline(x0, 3); vline(x1 - 3, 3)
        hline(y0, 3); hline(y1 - 3, 3)

        // Solid 1/8" square at the inset origin corner.
        ctx.fill(CGRect(x: x0, y: y0, width: step, height: step))

        guard let data = ctx.data else { return nil }
        let raw = data.bindMemory(to: UInt8.self, capacity: pw * ph)
        var pixels = [UInt8](repeating: 0, count: pw * ph)
        for j in 0 ..< (pw * ph) { pixels[j] = raw[j] < 0x80 ? 0xFF : 0x00 }
        return (pixels, pw, ph)
    }
}

// BradyLabelSize.dpi is defined as a stored property in BradyCatalog.swift
