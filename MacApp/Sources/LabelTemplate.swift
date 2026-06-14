import Foundation
import CoreGraphics
import CoreText

/// A field placed on a label template, bound to a key from the wire record.
struct TemplateField: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var fieldKey: String        // matches a key in WireRecord.fields, e.g. "CableName"
    var x: Double               // normalized 0-1 within label
    var y: Double
    var width: Double           // normalized 0-1
    var height: Double
    var fontWeight: FontWeight = .regular
    var alignment: TextAlignment = .left
    var autoFit: Bool = true
    var maxFontSize: Double = 24
    var minFontSize: Double = 8

    enum FontWeight: String, Codable { case regular, bold, black }
    enum TextAlignment: String, Codable { case left, center, right }
}

/// A saved label template, locked to a specific Brady label size.
struct LabelTemplate: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var partNumber: String      // BradyCatalog part number, e.g. "BM-32-427"
    var fields: [TemplateField]

    var labelSize: BradyLabelSize? {
        BradyCatalog.size(forPartNumber: partNumber)
    }
}

/// A single label's data, keyed by the same field names used in templates.
/// One WireRecord exists per side (source/destination) of each wire.
struct WireRecord: Identifiable, Hashable {
    var id: UUID = UUID()
    var side: String            // "Source" or "Destination"
    var wireID: String
    var fields: [String: String] // all ConnectCAD fields, raw + combined
}

/// Renders a LabelTemplate + WireRecord to a 1bpp mono pixel buffer
/// suitable for BradyVGL.buildPrintJob.
enum LabelRenderer {

    /// Returns row-major 1-byte-per-pixel buffer, 0xFF = black, 0x00 = white.
    static func render(template: LabelTemplate, record: WireRecord) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let size = template.labelSize else { return nil }
        let width = size.pixelWidth
        let height = size.pixelHeight

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }

        // White background
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0.0, alpha: 1.0)

        // Flip coordinate system so (0,0) is top-left like the canvas version
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        for field in template.fields {
            let text = record.fields[field.fieldKey] ?? ""
            drawField(text, field: field, in: ctx, labelWidth: width, labelHeight: height)
        }

        guard let data = ctx.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)

        // Threshold to 1bpp: anything darker than mid-gray = ink (0xFF)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            pixels[i] = buffer[i] < 0x80 ? 0xFF : 0x00
        }

        return (pixels, width, height)
    }

    private static func drawField(_ text: String, field: TemplateField, in ctx: CGContext, labelWidth: Int, labelHeight: Int) {
        guard !text.isEmpty else { return }

        let rect = CGRect(
            x: field.x * Double(labelWidth),
            y: field.y * Double(labelHeight),
            width: field.width * Double(labelWidth),
            height: field.height * Double(labelHeight)
        )

        let weight: CGFloat
        switch field.fontWeight {
        case .regular: weight = 0.0
        case .bold: weight = 0.4
        case .black: weight = 0.62
        }

        var fontSize = CGFloat(field.maxFontSize)
        var attrString: NSAttributedString = makeAttributedString(text, size: fontSize, weight: weight, alignment: field.alignment)

        if field.autoFit {
            while fontSize > CGFloat(field.minFontSize) {
                let bounds = attrString.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], context: nil)
                if bounds.width <= rect.width && bounds.height <= rect.height {
                    break
                }
                fontSize -= 1
                attrString = makeAttributedString(text, size: fontSize, weight: weight, alignment: field.alignment)
            }
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    private static func makeAttributedString(_ text: String, size: CGFloat, weight: CGFloat, alignment: TemplateField.TextAlignment) -> NSAttributedString {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Helvetica Neue",
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)

        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ])
    }
}
