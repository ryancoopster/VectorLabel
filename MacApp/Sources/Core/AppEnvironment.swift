import Foundation

public enum AppEnvironment {
    public static var isBeta: Bool { Bundle.main.bundleIdentifier?.contains(".beta.") ?? false }
    public static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(isBeta ? "VectorLabel Beta" : "VectorLabel", isDirectory: true)
    }
    public static var ipcRoot: URL { supportRoot.appendingPathComponent("ipc", isDirectory: true) }
}
