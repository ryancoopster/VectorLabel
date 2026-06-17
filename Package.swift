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
            dependencies: ["VectorLabelCore", "CLibUSB"],
            path: "MacApp/Sources/EngineKit"
        ),
        .target(
            name: "VectorLabelUI",
            dependencies: ["VectorLabelCore"],
            path: "MacApp/Sources/UI",
            linkerSettings: appLinkerSettings
        ),

        // MARK: – Executables (one @main each)

        .executableTarget(
            name: "VectorLabelEngine",
            dependencies: ["VectorLabelCore", "VectorLabelEngineKit", "VectorLabelUI"],
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
            dependencies: ["VectorLabelCore"],
            path: "MacApp/Tests"
        ),
    ]
)
