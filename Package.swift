// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VectorLabel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VectorLabel", targets: ["VectorLabel"]),
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
            path: "MacApp/Sources/Core",
            resources: [
                .copy("BradyCatalog.json"),
                .copy("VectorLabelPrint.html"),
                .copy("VectorLabelDesigner.html"),
                .copy("MenuBarIcon.png"),
                .copy("AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
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
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
        .executableTarget(
            name: "VectorLabel",
            dependencies: ["VectorLabelCore", "VectorLabelEngineKit", "VectorLabelUI"],
            path: "MacApp/Sources",
            exclude: [
                "Core",
                "CLibUSB",
                "EngineKit",
                "UI",
                "Info.plist",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
        .testTarget(
            name: "VectorLabelTests",
            dependencies: ["VectorLabelCore"],
            path: "MacApp/Tests"
        ),
    ]
)
