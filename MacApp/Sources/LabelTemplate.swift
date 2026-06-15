import Foundation
import CoreGraphics
import CoreText
import AppKit

// WireRecord is defined in ExportWatcher.swift.
// VLTemplate and TemplateObject are defined in TemplateStore.swift.
// This file contains only the renderer.

// MARK: – Brady label geometry

extension BradyLabelSize {
    /// Printable area in inches. For BM-33-427 the printable zone is 1.5×1.5,
    /// even though the total label is 4×1.5.
    var printableWidthInches: Double {
        switch partNumber {
        case "BM-31-427": return 1.0
        case "BM-32-427": return 1.5
        case "BM-33-427": return 1.5
        default: return widthInches
        }
    }

    var printableHeightInches: Double {
        switch partNumber {
        case "BM-31-427": return 0.5
        case "BM-32-427": return 0.5
        case "BM-33-427": return 1.5
        default: return heightInches
        }
    }

    var printablePixelWidth:  Int { Int((printableWidthInches  * Double(dpi)).rounded()) }
    var printablePixelHeight: Int { Int((printableHeightInches * Double(dpi)).rounded()) }
}

// MARK: – Renderer

/// Renders a VLTemplate + WireRecord to a 1-byte-per-pixel mono buffer
/// (0xFF = ink/black, 0x00 = white) suitable for BradyVGL.buildPrintJob.
enum LabelRenderer {

    /// SC is the coordinate scale used by the HTML designer: 185 px per inch-unit.
    /// Template object coordinates are in 0…1 relative to the printable area.
    /// We map those onto the actual print DPI here.
    static func render(template: VLTemplate, record: WireRecord) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let size = template.labelSize else { return nil }
        let pw = size.printablePixelWidth
        let ph = size.printablePixelHeight

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

        for obj in template.objs {
            switch obj.t {
            case "tx": drawText(obj, record: record, in: ctx, pw: pw, ph: ph)
            case "ln": drawLine(obj, in: ctx, pw: pw, ph: ph)
            case "rc": drawRect(obj, in: ctx, pw: pw, ph: ph)
            default: break
            }
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

    private static func rect(for obj: TemplateObject, pw: Int, ph: Int) -> CGRect {
        CGRect(
            x: obj.x * Double(pw),
            y: obj.y * Double(ph),
            width:  (obj.w) * Double(pw),
            height: (obj.h) * Double(ph)
        )
    }

    private static func drawText(_ obj: TemplateObject, record: WireRecord, in ctx: CGContext, pw: Int, ph: Int) {
        let formula = obj.f ?? ""
        let text = FormulaEngine.evaluate(formula, fields: record.fields)
        guard !text.isEmpty else { return }

        let r = rect(for: obj, pw: pw, ph: ph)

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

        // The HTML designer uses font-size in points at SC=185 (px per label unit).
        // We need to scale to the actual render DPI: (fs / 185) * dpi.
        // obj.fs is already in pt relative to the 185-px canvas.
        // In the HTML designer, font size is specified at SC=185 (185px per label unit).
        // The HTML renders: fz = (obj.fs / 100) * 185 px
        // For print at 300 DPI, scale by 300/185.
        let designerDPI = 185.0
        let printDPI    = 300.0
        let rawPt       = obj.fs ?? 14.0
        let fontSize    = rawPt * (printDPI / designerDPI)

        var traits: NSFontTraitMask = []
        if obj.bold   == true { traits.insert(.boldFontMask) }
        if obj.italic == true { traits.insert(.italicFontMask) }

        let fontManager = NSFontManager.shared
        var nsFont: NSFont
        if let base = NSFont(name: fontName, size: CGFloat(fontSize)) {
            nsFont = traits.isEmpty ? base : fontManager.convert(base, toHaveTrait: traits)
        } else {
            nsFont = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: obj.bold == true ? .bold : .regular)
        }

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
            attrs[.kern] = CGFloat(tracking) * CGFloat(pw) / CGFloat(sc)
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

        // Horizontal stretch (scaleX)
        let stretch = (obj.stretch ?? 100.0) / 100.0
        if abs(stretch - 1.0) > 0.01 {
            ctx.saveGState()
            ctx.translateBy(x: drawRect.origin.x, y: drawRect.origin.y)
            ctx.scaleBy(x: CGFloat(stretch), y: 1.0)
            let scaledRect = CGRect(origin: .zero, size: drawRect.size)
            let path = CGPath(rect: scaledRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        } else {
            let path = CGPath(rect: drawRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
        }
    }

    private static func drawLine(_ obj: TemplateObject, in ctx: CGContext, pw: Int, ph: Int) {
        let x1 = obj.x * Double(pw)
        let y  = obj.y * Double(ph)
        let x2 = (obj.x + obj.w) * Double(pw)
        let lw = max(1.0, obj.lw ?? 1.0) * Double(pw) / Double(pw)

        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setLineWidth(CGFloat(lw))
        ctx.move(to: CGPoint(x: x1, y: y))
        ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
    }

    private static func drawRect(_ obj: TemplateObject, in ctx: CGContext, pw: Int, ph: Int) {
        let r = rect(for: obj, pw: pw, ph: ph)
        let lw = max(1.0, obj.lw ?? 1.0)
        ctx.setStrokeColor(gray: 0.0, alpha: 1.0)
        ctx.setLineWidth(CGFloat(lw))
        ctx.stroke(r)
    }
}

// BradyLabelSize.dpi is defined as a stored property in BradyCatalog.swift
