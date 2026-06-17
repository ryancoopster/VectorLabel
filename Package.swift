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
        .executableTarget(
            name: "VectorLabel",
            dependencies: ["CLibUSB"],
            path: "MacApp/Sources",
            exclude: [
                "CLibUSB",
                "Info.plist",
            ],
            resources: [
                .copy("VectorLabelPrint.html"),
                .copy("VectorLabelDesigner.html"),
                .copy("AppIcon.icns"),
                .copy("MenuBarIcon.png"),
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
            dependencies: ["VectorLabel"],
            path: "MacApp/Tests"
        ),
    ]
)
