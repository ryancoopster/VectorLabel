import AppKit

public enum CoreResources {
    public static var bundle: Bundle { Bundle.module }
    public static func url(_ name: String, _ ext: String) -> URL? { Bundle.module.url(forResource: name, withExtension: ext) }
    public static func image(_ name: String, _ ext: String) -> NSImage? { url(name, ext).flatMap { NSImage(contentsOf: $0) } }
}
