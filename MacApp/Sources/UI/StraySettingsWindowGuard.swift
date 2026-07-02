import AppKit

// MARK: – Stray SwiftUI Settings-window guard

/// Closes the stray empty SwiftUI Settings-scene window, app-wide.
///
/// Every VectorLabel app's SwiftUI entry point is `Settings { EmptyView() }` (the
/// status item and all real windows are AppKit, owned by the AppDelegate) — but
/// macOS can present that lone scene as an empty "<App Name> Settings" window:
/// macOS 26 presents it at launch, and any activation (Dock click, `open`, the
/// installer relaunch, `NSApp.activate` before a modal) can present it again.
/// There is no way to declare "never show this scene" on our macOS 14 deployment
/// target (`defaultLaunchBehavior(.suppressed)` needs the macOS 15 SDK), so this
/// guard closes the window the moment it exists instead: `install()` sweeps at
/// launch and re-sweeps whenever the app becomes active or a stray window becomes
/// key/main.
///
/// Matching is strict — the SwiftUI-generated identifier prefix, or the exact
/// "<display name> Settings" title — so real app windows (the Engine's
/// "VectorLabel Preferences" panel, the "Software Update" download panel, the
/// designers' document windows) can never match.
@MainActor
public enum StraySettingsWindowGuard {

    private static var observers: [NSObjectProtocol] = []

    /// Call once, early in `applicationDidFinishLaunching`.
    public static func install() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                        object: nil, queue: .main) { _ in
            Self.sweepSoon()
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                if let window = note.object as? NSWindow, Self.isStray(window) { window.close() }
            })
        }
        sweepSoon()
    }

    /// Sweep now, on the next main-queue drain (a just-presented scene window
    /// exists by then), and again shortly after (activation can present it late).
    public static func sweepSoon() {
        sweep()
        DispatchQueue.main.async { Self.sweep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.sweep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { Self.sweep() }
    }

    public static func sweep() {
        for window in NSApp.windows where isStray(window) { window.close() }
    }

    private static func isStray(_ window: NSWindow) -> Bool {
        if (window.identifier?.rawValue ?? "").hasPrefix("com_apple_SwiftUI_Settings") { return true }
        return window.title == strayTitle
    }

    /// "<CFBundleDisplayName> Settings" — e.g. "VectorLabel Engine Settings".
    private static let strayTitle: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String) ?? ""
        return name + " Settings"
    }()
}
