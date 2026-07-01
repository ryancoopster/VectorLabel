import AppKit

/// A horizontal tab strip — one chip per open document/export (title + close ×), an
/// optional trailing "+" button, active-tab highlight, and a dirty dot for unsaved docs.
/// Used by the print + designer windows for multi-tab support. Rebuilds its chips on
/// `setItems`; the host owns the tab model and one WKWebView per tab.
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

    private let stack = NSStackView()
    private let addButton = NSButton()
    private let showsAdd: Bool
    private var activeID: String?

    init(showsAdd: Bool) {
        self.showsAdd = showsAdd
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 33).isActive = true

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        // A subtle bar background + a hairline bottom separator, adapting to appearance.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func setItems(_ items: [Item], active: String?) {
        activeID = active
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeChip(item)) }
        if showsAdd { stack.addArrangedSubview(addButton) }
        needsDisplay = true
    }

    private func makeChip(_ item: Item) -> NSView {
        let active = (item.id == activeID)
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        chip.layer?.backgroundColor = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: 25).isActive = true

        let title = NSButton(title: (item.dirty ? "• " : "") + item.title,
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
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        chip.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return chip
    }

    @objc private func chipClicked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onSelect?(id) } }
    @objc private func closeClicked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onClose?(id) } }
    @objc private func addClicked() { onAdd?() }
}
