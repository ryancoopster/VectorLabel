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
        // module.modulemap header path by architecture:
        //   Apple Silicon: /opt/homebrew/include/libusb-1.0/libusb.h  ← default
        //   Intel Mac:     /usr/local/include/libusb-1.0/libusb.h
        // Edit MacApp/Sources/CLibUSB/module.modulemap if on Intel.
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
                "CLibUSB",  // system library in its own subfolder
            ],
            resources: [
                .copy("VectorLabelPrint.html"),
                .copy("VectorLabelDesigner.html"),
            ],
            // Info.plist is at the repo root.
            // In Xcode: Target → Build Settings → INFOPLIST_FILE = Info.plist
            // For swift build: set MACOSX_BUNDLE_INFO_PLIST environment variable.
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
    ]
)
