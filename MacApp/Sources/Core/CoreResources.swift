import AppKit

/// Private token class whose defining image we can locate at runtime via `dladdr`.
/// This lets us find the resource bundle next to our *compiled code* — which is
/// where SwiftPM places `VectorLabel_VectorLabelCore.bundle` relative to — without
/// ever touching `Bundle.module` (whose generated accessor `fatalError`s when it
/// can't find the resource bundle in its two hard-coded locations).
private final class CoreResourcesToken {}

public enum CoreResources {
    /// Name of the SwiftPM-generated resource bundle for the VectorLabelCore target.
    private static let resourceBundleName = "VectorLabel_VectorLabelCore.bundle"

    /// Directory of the Mach-O image that contains this Core code, via `dladdr` on
    /// a Core symbol. In a packaged .app this is `Foo.app/Contents/MacOS`; under
    /// `swift test` it's the xctest's `Contents/MacOS`. The resource bundle is
    /// always somewhere at-or-above this directory, so we probe it and a few
    /// ancestors.
    private static var imageDirectory: URL? {
        var info = Dl_info()
        let ptr = unsafeBitCast(CoreResourcesToken.self, to: UnsafeRawPointer.self)
        guard dladdr(ptr, &info) != 0, let fname = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: fname)).deletingLastPathComponent()
    }

    /// Resolve the Core resource bundle ourselves, trying every plausible location
    /// a packaged or development/test build might place it. Returns `Bundle.main`
    /// as a non-crashing fallback so a missing resource bundle degrades gracefully
    /// (callers fall back to their own hard-coded data) rather than aborting.
    public static let bundle: Bundle = {
        var candidates: [URL] = []

        // Packaged .app: package-suite.sh copies the bundle into Contents/Resources.
        if let url = Bundle.main.resourceURL { candidates.append(url) }

        // Bundle that contains our code (framework or executable dir) + its root.
        let token = Bundle(for: CoreResourcesToken.self)
        if let url = token.resourceURL { candidates.append(url) }
        candidates.append(token.bundleURL)

        // The .app root (where Bundle.module's accessor also looks).
        candidates.append(Bundle.main.bundleURL)

        // Directory containing the running executable.
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir)
        }

        // The image directory and a few ancestors. Covers the packaged-app layout
        // (Contents/MacOS → Contents/Resources is found via Bundle.main above) and
        // the SwiftPM build/test layout, where the bundle sits beside the binary's
        // .build/<config> directory (xctest/Contents/MacOS → up to .build/<config>).
        if let imgDir = imageDirectory {
            var dir = imgDir
            for _ in 0..<4 {
                candidates.append(dir)
                dir = dir.deletingLastPathComponent()
            }
        }

        for base in candidates {
            let url = base.appendingPathComponent(resourceBundleName)
            if let found = Bundle(url: url) {
                return found
            }
        }

        // Last resort: don't crash. Callers (e.g. BradyCatalog) have their own
        // fallbacks when a resource can't be found.
        return Bundle.main
    }()

    public static func url(_ name: String, _ ext: String) -> URL? { bundle.url(forResource: name, withExtension: ext) }
    public static func image(_ name: String, _ ext: String) -> NSImage? { url(name, ext).flatMap { NSImage(contentsOf: $0) } }
}
