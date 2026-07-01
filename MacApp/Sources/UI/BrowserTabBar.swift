import AppKit

/// A horizontal tab strip — one chip per open document/export (title + close ×), an
/// optional trailing "+" button, active-tab highlight, and a dirty dot for unsaved docs.
/// When the chips don't all fit, the strip scrolls and ‹ › arrows appear at either end to
/// page through the tabs (chips keep their natural width — they never squeeze down to just
/// an ×). Used by the print + designer windows; the host owns the tab model + one WKWebView
/// per tab, and rebuilds the chips via `setItems`.
@MainActor
final class BrowserTabBar: NSView {
    struct Item {
        let id: String
        let title: String
        var dirty: Bool
        init(id: String, title: String, dirty: Bool = false) { self.id = id; self.title = title; self.dirty = dirty }
    }

    /// Fired when the user clicks a tab chip / its close × / the + button.
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onAdd: (() -> Void)?

    private let stack = NSStackView()          // the chip strip (document view of the scroller)
    private let scrollView = NSScrollView()
    private let leftArrow = NSButton()
    private let rightArrow = NSButton()
    private let addButton = NSButton()
    private let showsAdd: Bool
    private var activeID: String?

    init(showsAdd: Bool) {
        self.showsAdd = showsAdd
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 33).isActive = true

        // Chip strip.
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Horizontal scroller hosting the strip (no visible scrollbars — the arrows drive it).
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = stack
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Keep the ‹ › enabled-state fresh after a two-finger/trackpad scroll (not just on layout).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            // trailing intentionally free → the strip takes its natural width and scrolls.
        ])

        configureArrow(leftArrow, symbol: "chevron.left", fallback: "‹", action: #selector(pageLeft))
        configureArrow(rightArrow, symbol: "chevron.right", fallback: "›", action: #selector(pageRight))
        leftArrow.isHidden = true
        rightArrow.isHidden = true

        addButton.title = "+"
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.toolTip = "New tab"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        addButton.isHidden = !showsAdd

        // Top-level row: ‹ | scrolling strip | › | +   (arrows collapse when not overflowing).
        let views: [NSView] = showsAdd ? [leftArrow, scrollView, rightArrow, addButton]
                                       : [leftArrow, scrollView, rightArrow]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureArrow(_ b: NSButton, symbol: String, fallback: String, action: Selector) {
        b.bezelStyle = .inline
        b.isBordered = false
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.contentTintColor = .secondaryLabelColor
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            b.image = img
            b.imagePosition = .imageOnly
        } else {
            b.title = fallback
            b.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        }
    }

    override var isFlipped: Bool { true }

    // Paint in draw(_:) (which always runs for a wantsLayer view that overrides it) — a bare
    // updateLayer() never fired because wantsUpdateLayer defaults to false. Re-resolving the
    // colors here also adapts them to a light/dark switch.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true   // re-resolve the bar colors on a light/dark switch
    }

    override func layout() {
        super.layout()
        updateArrows()   // window resize can create/remove overflow
    }

    func setItems(_ items: [Item], active: String?) {
        activeID = active
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeChip(item)) }
        needsDisplay = true
        // Layout hasn't run yet — evaluate overflow + reveal the active chip next tick.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scrollTo(self.scrollX, animated: false)   // re-clamp: closing tabs can shrink the strip below the current offset
            self.updateArrows()
            self.scrollActiveIntoView()
        }
    }

    // MARK: – Scrolling / overflow arrows

    private var contentWidth: CGFloat { stack.fittingSize.width }
    private var clipWidth: CGFloat { scrollView.contentView.bounds.width }
    private var maxScrollX: CGFloat { max(0, contentWidth - clipWidth) }
    private var scrollX: CGFloat { scrollView.contentView.bounds.origin.x }

    private func updateArrows() {
        let overflow = contentWidth > clipWidth + 1
        leftArrow.isHidden = !overflow
        rightArrow.isHidden = !overflow
        if overflow {
            leftArrow.isEnabled = scrollX > 1
            rightArrow.isEnabled = scrollX < maxScrollX - 1
        }
    }

    private func scrollTo(_ x: CGFloat, animated: Bool) {
        let clamped = max(0, min(maxScrollX, x))
        let clip = scrollView.contentView
        let target = NSPoint(x: clamped, y: clip.bounds.origin.y)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18; ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self] in self?.updateArrows() })
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
        updateArrows()
    }

    @objc private func pageLeft()  { scrollTo(scrollX - max(120, clipWidth * 0.8), animated: true) }
    @objc private func pageRight() { scrollTo(scrollX + max(120, clipWidth * 0.8), animated: true) }
    @objc private func clipBoundsChanged() { updateArrows() }

    /// Keep the active chip visible (e.g. after switching to an off-screen tab).
    private func scrollActiveIntoView() {
        guard contentWidth > clipWidth + 1,
              let id = activeID,
              let chip = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == id })
        else { return }
        let f = chip.frame   // in the flipped stack's coordinates
        if f.minX < scrollX { scrollTo(f.minX - 8, animated: false) }
        else if f.maxX > scrollX + clipWidth { scrollTo(f.maxX - clipWidth + 8, animated: false) }
    }

    // MARK: – Chips

    private func makeChip(_ item: Item) -> NSView {
        let active = (item.id == activeID)
        let chip = NSView()
        chip.identifier = NSUserInterfaceItemIdentifier(item.id)   // so scrollActiveIntoView can find it
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        chip.layer?.backgroundColor = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: 25).isActive = true

        // Show the whole file name, but cap at 50 characters (then ellipsize) so one very
        // long name can't create a monster chip. The chip sizes to this text below.
        let name = item.title.count > 50 ? String(item.title.prefix(50)) + "…" : item.title
        let title = NSButton(title: (item.dirty ? "• " : "") + name,
                             target: self, action: #selector(chipClicked(_:)))
        title.bezelStyle = .inline
        title.isBordered = false
        title.identifier = NSUserInterfaceItemIdentifier(item.id)
        title.contentTintColor = active ? .labelColor : .secondaryLabelColor
        title.font = NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .left
        title.toolTip = item.title
        title.translatesAutoresizingMaskIntoConstraints = false
        // Keep the natural width (don't squeeze titles away) — long titles cap at 220 below.
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked(_:)))
        close.bezelStyle = .inline
        close.isBordered = false
        close.identifier = NSUserInterfaceItemIdentifier(item.id)
        close.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close tab"
        close.translatesAutoresizingMaskIntoConstraints = false
        close.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let h = NSStackView(views: [title, close])
        h.orientation = .horizontal
        h.spacing = 3
        h.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 5)
        h.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            h.topAnchor.constraint(equalTo: chip.topAnchor),
            h.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
        ])
        // No fixed max width — the chip grows to fit the (≤50-char) name so text never spills
        // over the ✕. The strip scrolls (with ‹ › arrows) when the chips overrun the bar.
        return chip
    }

    @objc private func chipClicked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onSelect?(id) } }
    @objc private func closeClicked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onClose?(id) } }
    @objc private func addClicked() { onAdd?() }
}
