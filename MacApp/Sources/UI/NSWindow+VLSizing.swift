import AppKit
import ObjectiveC

// MARK: – Window sizing + persistence
//
// Shared window-sizing helper. Lives in VectorLabelUI (pure AppKit, no EngineKit)
// so both the print window here and the designer/preferences windows in the
// executable can use it.

private var kVLFrameKey: UInt8 = 0
private var kVLFrameTokens: UInt8 = 0

public extension NSWindow {
    /// Size a window so it opens at a sensible default (the smallest size where
    /// its controls don't wrap), remembers the user's manual resize across
    /// opens/launches, and never exceeds the current screen.
    ///
    /// The frame is persisted to UserDefaults ourselves (keyed by name) rather
    /// than via AppKit's frame-autosave-NAME mechanism, which silently stops
    /// working when a window is recreated on each open (the name is still held
    /// by the just-closed window). Save on resize/move, restore on open.
    func applyVLSizing(autosaveName: String, defaultContentSize: NSSize) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: defaultContentSize.width, height: defaultContentSize.height)

        // Default = the no-wrap size, but never larger than the screen.
        let defSize = NSSize(width: min(defaultContentSize.width, visible.width),
                             height: min(defaultContentSize.height, visible.height))
        contentMinSize = defSize

        // Opt out of macOS automatic window-state/tiling restoration, which was
        // reopening this window in a filled/tiled state and overriding our frame.
        isRestorable = false
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + autosaveName)  // stale AppKit autosave

        let key = "vlframe_" + autosaveName
        var restored = false
        if let s = UserDefaults.standard.string(forKey: key) {
            let r = NSRectFromString(s)
            if r.size.width >= 200 && r.size.height >= 200 { setFrame(r, display: false); restored = true }
        }
        if !restored { setContentSize(defSize); center() }

        // Clamp to the visible screen, enforcing the minimum (no-wrap) size.
        var f = frame
        f.size.width  = min(max(f.size.width, defSize.width), visible.width)
        f.size.height = min(max(f.size.height, defSize.height), visible.height)
        f.origin.x = max(visible.minX, min(f.origin.x, visible.maxX - f.size.width))
        f.origin.y = max(visible.minY, min(f.origin.y, visible.maxY - f.size.height))
        setFrame(f, display: false)

        // Re-assert the frame after the window is shown, in case AppKit/macOS
        // tiling snaps it on order-front.
        let target = f
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !NSEqualRects(self.frame, target) { self.setFrame(target, display: true) }
        }

        // Persist the frame on resize/move; clean the observers up on close.
        objc_setAssociatedObject(self, &kVLFrameKey, key, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if objc_getAssociatedObject(self, &kVLFrameTokens) == nil {
            let nc = NotificationCenter.default
            let save: (Notification) -> Void = { [weak self] _ in
                guard let self = self,
                      let k = objc_getAssociatedObject(self, &kVLFrameKey) as? String else { return }
                UserDefaults.standard.set(NSStringFromRect(self.frame), forKey: k)
            }
            var tokens: [NSObjectProtocol] = []
            tokens.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main, using: save))
            tokens.append(nc.addObserver(forName: NSWindow.didMoveNotification,   object: self, queue: .main, using: save))
            tokens.append(nc.addObserver(forName: NSWindow.willCloseNotification,  object: self, queue: .main, using: { [weak self] _ in
                guard let self = self else { return }
                if let ts = objc_getAssociatedObject(self, &kVLFrameTokens) as? [NSObjectProtocol] {
                    ts.forEach { nc.removeObserver($0) }
                }
                objc_setAssociatedObject(self, &kVLFrameTokens, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }))
            objc_setAssociatedObject(self, &kVLFrameTokens, tokens, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
