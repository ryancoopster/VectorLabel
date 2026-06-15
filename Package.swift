// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VectorLabel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VectorLabel", targets: ["VectorLabel"]),
    ],
    targets: [
        // Wraps libusb-1.0 so Swift can import it.
        // Requires: brew install libusb
        // The module.modulemap must point at the correct libusb header path.
        .systemLibrary(
            name: "CLibUSB",
            path: "MacApp/Sources",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .executableTarget(
            name: "VectorLabel",
            dependencies: ["CLibUSB"],
            path: "MacApp/Sources",
            exclude: ["module.modulemap"],   // handled by CLibUSB target
            resources: [
                // HTML UIs loaded in WKWebView at runtime
                .copy("VectorLabelPrint.html"),
                .copy("VectorLabelDesigner.html"),
                // Info.plist and entitlements are picked up by Xcode automatically;
                // for SPM builds we include them as resources so they're in the bundle.
                .copy("Info.plist"),
                .copy("VectorLabel.entitlements"),
            ],
            swiftSettings: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
    ]
)
