import AppKit

/// The replacement popover shown when `ClientPolicy.level == .block`.
/// Two buttons: open the download URL, or quit the app.
final class BlockPopoverView: NSView {
    var onDownload: (() -> Void)?
    var onQuit: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(message: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        setup(message: message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updateMessage(_ message: String) {
        messageLabel.stringValue = message.isEmpty ? "This version is no longer supported." : message
    }

    override var wantsUpdateLayer: Bool { true }

    /// Re-resolves the Horizon colours whenever the appearance changes.
    override func updateLayer() {
        layer?.backgroundColor = PopoverPalette.backgroundNS.cgColor
        icon.image = Self.warningImage(appearance: effectiveAppearance)
    }

    private static func warningImage(appearance: NSAppearance) -> NSImage {
        let image = HorizonGlyphs.image(HorizonGlyphs.warning, viewBox: 24, size: 30, lineWidth: 2) {
            StatusBarController.resolved(PopoverPalette.criticalNS, in: appearance)
        }
        image.accessibilityDescription = "Update required"
        return image
    }

    private func setup(message: String) {
        wantsLayer = true

        icon.image = Self.warningImage(appearance: effectiveAppearance)

        let title = NSTextField(labelWithString: "Update required")
        title.font = BrandFonts.nsSans(17, weight: .semibold)
        title.textColor = PopoverPalette.dynamic(light: 0x1A1614, dark: 0xFFFFFF)
        title.alignment = .center

        messageLabel.stringValue = message.isEmpty ? "This version is no longer supported." : message
        messageLabel.font = BrandFonts.nsSans(13)
        messageLabel.textColor = PopoverPalette.dynamic(light: 0x6B625A, dark: 0xCFC6BC)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 4
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.preferredMaxLayoutWidth = 280

        let download = PillButton(title: "Download Now", primary: true, target: self, action: #selector(downloadAction))
        download.keyEquivalent = "\r"  // make this the default

        let quit = PillButton(title: "Quit LobsterOne", primary: false, target: self, action: #selector(quitAction))

        let buttonStack = NSStackView(views: [quit, download])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.distribution = .fillEqually

        let stack = NSStackView(views: [icon, title, messageLabel, buttonStack])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(18, after: messageLabel)
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func downloadAction() { onDownload?() }
    @objc private func quitAction() { onQuit?() }
}

/// A 44pt pill: Lobster with white text for the main action, white with a Line strong border
/// for the other.
private final class PillButton: NSButton {
    private let primary: Bool
    private var hovering = false { didSet { applyColors() } }

    init(title: String, primary: Bool, target: AnyObject, action: Selector) {
        self.primary = primary
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // Dynamic colours in the title resolve when it is drawn, so it follows the appearance.
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: BrandFonts.nsSans(14, weight: .semibold),
            .foregroundColor: primary ? PopoverPalette.dynamic(light: 0xFFFFFF, dark: 0x1A1614)
                                      : PopoverPalette.dynamic(light: 0x1A1614, dark: 0xFFFFFF),
            .paragraphStyle: paragraph,
        ])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Layers keep a fixed colour, so each one is resolved for the current appearance.
    private func applyColors() {
        guard let layer else { return }
        let fill: NSColor
        if primary {
            fill = hovering ? PopoverPalette.dynamic(light: 0xA83C17, dark: 0xF39B70) : PopoverPalette.brandNS
            layer.borderWidth = 0
        } else {
            fill = hovering ? PopoverPalette.dynamic(light: 0xF5F0EA, dark: 0x26201C) : PopoverPalette.backgroundNS
            layer.borderWidth = 1
            layer.borderColor = StatusBarController.resolved(
                PopoverPalette.dynamic(light: 0xE6DED4, dark: 0x3A322C), in: effectiveAppearance).cgColor
        }
        layer.backgroundColor = StatusBarController.resolved(fill, in: effectiveAppearance).cgColor
    }
}
