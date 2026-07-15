import AppKit

final class PersistentActionMenu: NSMenu {
    private let refreshAction: () -> Void
    private weak var refreshItem: PersistentRefreshMenuItem?

    init(refreshAction: @escaping () -> Void) {
        self.refreshAction = refreshAction
        super.init(title: "")
        self.autoenablesItems = false
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func makeRefreshItem(
        title: String = "Refresh",
        width: CGFloat = 290
    ) -> PersistentRefreshMenuItem {
        let item = PersistentRefreshMenuItem(
            title: title,
            width: width,
            refreshAction: { [weak self] in self?.performRefresh() })
        self.refreshItem = item
        return item
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.isRefreshShortcut(event) else {
            return super.performKeyEquivalent(with: event)
        }
        self.performRefresh()
        return true
    }

    private func performRefresh() {
        guard self.refreshItem?.isEnabled == true else { return }
        self.refreshAction()
    }

    private static func isRefreshShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers == .command else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "r"
    }
}

final class PersistentRefreshMenuItem: NSMenuItem {
    private let refreshView: PersistentRefreshMenuView

    init(title: String, width: CGFloat, refreshAction: @escaping () -> Void) {
        self.refreshView = PersistentRefreshMenuView(title: title, refreshAction: refreshAction)
        super.init(title: title, action: nil, keyEquivalent: "")
        self.view = self.refreshView
        self.toolTip = "Refresh usage information"
        self.refreshView.applySize(width: width)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        self.refreshView.setEnabled(enabled)
    }

    func setHighlighted(_ highlighted: Bool) {
        self.refreshView.setHighlighted(highlighted && self.isEnabled)
    }
}

private struct PersistentRefreshRowMetrics {
    static let rowHeight: CGFloat = 24
    static let leadingPadding: CGFloat = 15
    static let trailingPadding: CGFloat = 8
    static let iconWidth: CGFloat = 16
    static let iconTitleSpacing: CGFloat = 4.5
    static let titleShortcutGap: CGFloat = 8
    static let minimumShortcutWidth: CGFloat = 44
    static let shortcutXOffset: CGFloat = -9.5
    static let selectionHorizontalInset: CGFloat = 5
    static let selectionCornerRadius: CGFloat = 7
}

final class PersistentRefreshMenuView: NSView {
    private let selectionView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let shortcutField = NSTextField(labelWithString: "⌘ R")
    private let refreshAction: () -> Void
    private var isRowEnabled = true
    private var isRowHighlighted = false

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: PersistentRefreshRowMetrics.rowHeight)
    }

    init(title: String, refreshAction: @escaping () -> Void) {
        self.titleField = NSTextField(labelWithString: title)
        self.refreshAction = refreshAction
        super.init(frame: .zero)
        self.configureSelectionView()
        self.configureIconView()
        self.configureTextFields()
        self.installClickRecognizer()
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { self.titleField.stringValue }

    override func accessibilityHelp() -> String? { "Refresh usage information" }

    override func isAccessibilityEnabled() -> Bool { self.isRowEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard self.isRowEnabled else { return false }
        self.refreshAction()
        return true
    }

    func applySize(width: CGFloat) {
        self.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: PersistentRefreshRowMetrics.rowHeight))
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    func setEnabled(_ enabled: Bool) {
        self.isRowEnabled = enabled
        if !enabled {
            self.isRowHighlighted = false
            self.selectionView.isHidden = true
        }
        self.updateColors()
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.isRowHighlighted != highlighted else { return }
        self.isRowHighlighted = highlighted
        self.selectionView.isHidden = !highlighted
        self.updateColors()
    }

    override func layout() {
        super.layout()
        let metrics = PersistentRefreshRowMetrics.self
        self.selectionView.frame = self.bounds.insetBy(dx: metrics.selectionHorizontalInset, dy: 0)
        self.selectionView.layer?.cornerRadius = metrics.selectionCornerRadius

        self.iconView.frame = NSRect(
            x: metrics.leadingPadding,
            y: floor((self.bounds.height - metrics.iconWidth) / 2),
            width: metrics.iconWidth,
            height: metrics.iconWidth)

        let shortcutSize = self.shortcutField.intrinsicContentSize
        let referenceWidth = ("⌘ R" as NSString).size(withAttributes: [
            .font: NSFont.menuFont(ofSize: 13),
        ]).width
        let shortcutWidth = max(metrics.minimumShortcutWidth, shortcutSize.width)
        self.shortcutField.frame = NSRect(
            x: self.bounds.maxX
                - metrics.trailingPadding
                + metrics.shortcutXOffset
                - referenceWidth,
            y: floor((self.bounds.height - shortcutSize.height) / 2),
            width: shortcutWidth,
            height: shortcutSize.height)

        let titleX = metrics.leadingPadding + metrics.iconWidth + metrics.iconTitleSpacing
        let titleSize = self.titleField.intrinsicContentSize
        self.titleField.frame = NSRect(
            x: titleX,
            y: floor((self.bounds.height - titleSize.height) / 2),
            width: max(0, self.shortcutField.frame.minX - metrics.titleShortcutGap - titleX),
            height: titleSize.height)
    }

    private func configureSelectionView() {
        self.selectionView.material = .selection
        self.selectionView.blendingMode = .withinWindow
        self.selectionView.state = .active
        self.selectionView.isEmphasized = true
        self.selectionView.isHidden = true
        self.selectionView.wantsLayer = true
        self.selectionView.layer?.masksToBounds = true
        self.addSubview(self.selectionView)
    }

    private func configureIconView() {
        let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        image?.isTemplate = true
        self.iconView.image = image
        self.iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        self.iconView.imageScaling = .scaleProportionallyDown
        self.addSubview(self.iconView)
    }

    private func configureTextFields() {
        self.titleField.font = NSFont.menuFont(ofSize: 0)
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.maximumNumberOfLines = 1
        self.titleField.allowsDefaultTighteningForTruncation = true
        self.addSubview(self.titleField)

        self.shortcutField.font = NSFont.menuFont(ofSize: 13)
        self.shortcutField.alignment = .left
        self.shortcutField.lineBreakMode = .byClipping
        self.shortcutField.maximumNumberOfLines = 1
        self.addSubview(self.shortcutField)
    }

    private func installClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
    }

    private func updateColors() {
        guard self.isRowEnabled else {
            self.titleField.textColor = .disabledControlTextColor
            self.shortcutField.textColor = .disabledControlTextColor
            self.iconView.contentTintColor = .disabledControlTextColor
            return
        }
        if self.isRowHighlighted {
            self.titleField.textColor = .selectedMenuItemTextColor
            self.shortcutField.textColor = .selectedMenuItemTextColor
            self.iconView.contentTintColor = .selectedMenuItemTextColor
        } else {
            self.titleField.textColor = .labelColor
            self.shortcutField.textColor = .tertiaryLabelColor
            self.iconView.contentTintColor = .labelColor
        }
    }

    @objc private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard self.isRowEnabled else { return }
        self.refreshAction()
    }
}
