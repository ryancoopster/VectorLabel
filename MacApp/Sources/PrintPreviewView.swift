import SwiftUI

/// Foreground window shown when a new export is detected.
/// User picks a template (which locks the required label size/part number),
/// reviews records with a live preview, then prints.
struct PrintPreviewView: View {
    let records: [WireRecord]
    let templates: [LabelTemplate]
    let onClose: () -> Void
    let onPrint: ([[UInt8]], String) -> Void

    @State private var selectedTemplate: LabelTemplate?
    @State private var selectedRecordID: WireRecord.ID?

    private var selectedRecord: WireRecord? {
        records.first { $0.id == selectedRecordID } ?? records.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HSplitView {
                recordList
                    .frame(minWidth: 250)

                previewPane
                    .frame(minWidth: 400)
            }

            footer
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if selectedTemplate == nil { selectedTemplate = templates.first }
            if selectedRecordID == nil { selectedRecordID = records.first?.id }
        }
    }

    private var header: some View {
        HStack {
            Text("Template:")
            Picker("", selection: $selectedTemplate) {
                Text("Select a template").tag(LabelTemplate?.none)
                ForEach(templates) { template in
                    Text(template.name).tag(LabelTemplate?.some(template))
                }
            }
            .frame(width: 240)

            Spacer()

            if let template = selectedTemplate, let size = template.labelSize {
                Text("Load: \(size.partNumber) — \(size.displayName)")
                    .font(.headline)
                    .padding(8)
                    .background(Color.yellow.opacity(0.3))
                    .cornerRadius(6)
            } else {
                Text("Select a template to see required label")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var recordList: some View {
        List(records, selection: $selectedRecordID) { record in
            VStack(alignment: .leading) {
                Text("\(record.fields["WireID"] ?? "") — \(record.side)")
                    .font(.body)
                Text(record.fields["CableName"] ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .tag(record.id)
        }
    }

    private var previewPane: some View {
        VStack {
            if let template = selectedTemplate, let record = selectedRecord,
               let rendered = LabelRenderer.render(template: template, record: record) {
                LabelPreviewImage(pixels: rendered.pixels, width: rendered.width, height: rendered.height)
                    .border(Color.gray)
                    .padding()
            } else {
                Text("No preview available — select a template")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onClose() }
            Button("Print \(records.count) Label(s)") {
                print()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTemplate == nil)
        }
        .padding()
    }

    private func print() {
        guard let template = selectedTemplate else { return }
        var jobs: [[UInt8]] = []
        for record in records {
            guard let rendered = LabelRenderer.render(template: template, record: record) else { continue }
            let job = BradyVGL.buildPrintJob(pixels: rendered.pixels, width: rendered.width, height: rendered.height)
            jobs.append(job)
        }
        onPrint(jobs, template.partNumber)
    }
}

/// Renders a 1bpp pixel buffer to a SwiftUI Image for preview.
struct LabelPreviewImage: View {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    var body: some View {
        if let cgImage = makeCGImage() {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.gray
        }
    }

    private func makeCGImage() -> CGImage? {
        var data = pixels
        // Invert: pixels are 0xFF=ink/black, want display where ink shows black
        for i in 0..<data.count { data[i] = data[i] == 0xFF ? 0 : 255 }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: width, space: colorSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
