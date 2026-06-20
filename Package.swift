// swift-tools-version: 5.9
import PackageDescription

let appLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("WebKit"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
]

let package = Package(
    name: "VectorLabel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VectorLabelEngine", targets: ["VectorLabelEngine"]),
        .executable(name: "VectorLabelAutoPrint", targets: ["VectorLabelAutoPrint"]),
        .executable(name: "VectorLabelTemplateDesigner", targets: ["VectorLabelTemplateDesigner"]),
        .executable(name: "VectorLabelCustomDesigner", targets: ["VectorLabelCustomDesigner"]),
    ],
    dependencies: [
        // Phase 3: .xlsx reading for the Custom Designer's database binding.
        // Core-only — does NOT pull in libusb; stays out of the Engine constraint.
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.2"),
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            path: "MacApp/Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "VectorLabelCore",
            dependencies: ["CoreXLSX"],
            path: "MacApp/Sources/Core",
            // AppIconCustom.icns is consumed only by scripts/package-suite.sh from the
            // repo path (never via Bundle at runtime), so exclude it from the target to
            // silence SPM's "unhandled file" warning.
            exclude: ["AppIconCustom.icns", "AppIconTemplate.icns"],
            resources: [
                .copy("BradyCatalog.json"),
                .copy("VectorLabelPrint.html"),
                .copy("VectorLabelDesigner.html"),
                .copy("MenuBarIcon.png"),
                .copy("AppIcon.icns"),
            ],
            linkerSettings: appLinkerSettings
        ),
        .target(
            name: "VectorLabelEngineKit",
            dependencies: ["VectorLabelCore", "PrinterM610", "PrinterM611"],
            path: "MacApp/Sources/EngineKit"
        ),
        .target(
            name: "VectorLabelUI",
            dependencies: ["VectorLabelCore"],
            path: "MacApp/Sources/UI",
            linkerSettings: appLinkerSettings
        ),

        // MARK: – Per-printer modules (one self-contained module per printer).
        // Each conforms to the shared PrinterModule abstraction. M610 = USB/VGL
        // (links libusb), M611 = network bitmap/LZ4 over TCP (Foundation-only).
        .target(
            name: "PrinterM610",
            dependencies: ["VectorLabelCore", "CLibUSB"],
            path: "MacApp/Sources/PrinterM610"
        ),
        .target(
            name: "PrinterM611",
            dependencies: ["VectorLabelCore", "CLibUSB"],
            path: "MacApp/Sources/PrinterM611"
        ),

        // MARK: – Executables (one @main each)

        .executableTarget(
            name: "VectorLabelEngine",
            dependencies: ["VectorLabelCore", "VectorLabelEngineKit", "VectorLabelUI", "PrinterM610", "PrinterM611"],
            path: "MacApp/Sources/Engine",
            linkerSettings: appLinkerSettings
        ),
        .executableTarget(
            name: "VectorLabelAutoPrint",
            dependencies: ["VectorLabelCore", "VectorLabelUI"],
            path: "MacApp/Sources/AutoPrint",
            linkerSettings: appLinkerSettings
        ),
        .executableTarget(
            name: "VectorLabelTemplateDesigner",
            dependencies: ["VectorLabelCore", "VectorLabelUI"],
            path: "MacApp/Sources/TemplateDesigner",
            linkerSettings: appLinkerSettings
        ),
        .executableTarget(
            name: "VectorLabelCustomDesigner",
            dependencies: ["VectorLabelCore", "VectorLabelUI"],
            path: "MacApp/Sources/CustomDesigner",
            linkerSettings: appLinkerSettings
        ),

        .testTarget(
            name: "VectorLabelTests",
            dependencies: ["VectorLabelCore", "PrinterM611", "PrinterM610"],
            path: "MacApp/Tests",
            resources: [
                // Tiny inline-string .xlsx (no xl/sharedStrings.xml) used to verify
                // ExcelRecordReader tolerates a nil SharedStrings table.
                .copy("Fixtures/inline-no-sharedstrings.xlsx"),
                // .xlsx whose shared-strings table has a rich-text entry (runs, no
                // top-level <t>), used to verify the reader joins the runs instead
                // of emitting the raw shared-string index.
                .copy("Fixtures/richtext-sharedstrings.xlsx"),
            ]
        ),
    ]
)
