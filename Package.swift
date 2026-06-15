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
        //
        // Prerequisites (run in Terminal before opening in Xcode):
        //   brew install libusb pkg-config
        //
        // The module.modulemap path depends on your Mac architecture:
        //   Apple Silicon: /opt/homebrew/include/libusb-1.0/libusb.h  ← default
        //   Intel Mac:     /usr/local/include/libusb-1.0/libusb.h
        // Edit MacApp/Sources/CLibUSB/module.modulemap if you're on Intel.
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
                "CLibUSB",   // system library lives in its own subfolder
            ],
            resources: [
                .copy("VectorLabelPrint.html"),
                .copy("VectorLabelDesigner.html"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
    ]
)
