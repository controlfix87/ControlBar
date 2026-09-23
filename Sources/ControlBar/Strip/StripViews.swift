import AppKit

/// Borderless floating panel that never takes focus from the frontmost app.
final class StripPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Blurred rounded background of the strip; reports hover so auto-hide can pause.
final class StripBackgroundView: NSVisualEffectView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(cornerRadius: CGFloat = 10) {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.mask(radius: cornerRadius)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One clickable icon in the strip.
final class StripItemView: NSView {
    let item: MenuBarItem
    var onActivate: ((MenuBarItem, _ secondary: Bool) -> Void)?

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(item: MenuBarItem, image: NSImage?, scale: CGFloat = 1) {
        self.item = item
        super.init(frame: .zero)
        toolTip = item.displayName
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.displayName)

        let size: NSSize
        if let image {
            // A captured picture of the real item, already padded like the menu bar.
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            size = NSSize(width: max(image.size.width, 24) * scale, height: min(max(image.size.height, 24), 34) * scale)
        } else {
            // No picture available: show the owning app's icon.
            imageView.image = item.appIcon ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            size = NSSize(width: 30 * scale, height: 26 * scale)
        }
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let image {
            constraints += [imageView.widthAnchor.constraint(equalToConstant: image.size.width * scale),
                            imageView.heightAnchor.constraint(equalToConstant: image.size.height * scale)]
        } else {
            constraints += [imageView.widthAnchor.constraint(equalToConstant: 18 * scale),
                            imageView.heightAnchor.constraint(equalToConstant: 18 * scale)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        NSColor.labelColor.withAlphaComponent(isPressed ? 0.2 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onActivate?(item, event.modifierFlags.contains(.control))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?(item, true)
    }
}
