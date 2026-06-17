import AppKit
import VectorLabelCore

/// Launches the sibling Dock apps (Template Designer / Custom Designer) by bundle
/// identifier. The ids are beta-aware: the base id gets a ".beta" infix when this
/// process is the beta build (AppEnvironment.isBeta, read from the bundle id).
///
/// Launching only works in the packaged suite, where all four apps are installed
/// with the expected bundle ids. In a `swift build` dev run the lookup simply
/// fails and we no-op — that's expected and fine.
public enum DesignerAppLauncher {

    /// Which sibling app to launch.
    public enum Target {
        case template
        case custom
        case autoPrint

        /// Bundle-id stem (without the optional ".beta" infix).
        fileprivate var idLeaf: String {
            switch self {
            case .template:  return "templatedesigner"
            case .custom:    return "customdesigner"
            case .autoPrint: return "autoprint"
            }
        }
    }

    /// The beta-aware bundle identifier for a target, e.g.
    /// "com.sai.vectorlabel.templatedesigner" or, in beta,
    /// "com.sai.vectorlabel.beta.templatedesigner".
    public static func bundleID(for target: Target) -> String {
        let prefix = AppEnvironment.isBeta ? "com.sai.vectorlabel.beta" : "com.sai.vectorlabel"
        return "\(prefix).\(target.idLeaf)"
    }

    /// Locate the installed app by bundle id and launch (or activate) it. No-ops
    /// gracefully if the app isn't installed (dev builds).
    public static func launch(_ target: Target) {
        let id = bundleID(for: target)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            // Not installed (e.g. running from `swift build`): nothing to launch.
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("[DesignerAppLauncher] launch \(id) failed: \(error.localizedDescription)") }
        }
    }
}
