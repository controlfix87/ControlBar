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

/// The ┃ glyph inside `DividerMarkPanel`; a click on it asks to start arranging.
private final class DividerMarkView: NSImageView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A ┃ drawn on the menu bar itself, at the right edge of the stretched divider item (the boundary between
/// hidden and visible icons), so the marker stays visible while the strip is open. It can't be dragged (it
/// isn't a status item; the real divider is stretched off-screen while icons are hidden), so clicking it
/// starts Arrange mode, where the real ┃ is back on the bar and can be ⌘-dragged.
final class DividerMarkPanel: NSPanel {
    private let markView = DividerMarkView()
    /// Called when the ┃ is clicked.
    var onClick: (() -> Void)? {
        get { markView.onClick }
        set { markView.onClick = newValue }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        markView.image = StatusBarController.dividerImage
        markView.imageScaling = .scaleNone
        markView.imageAlignment = .alignCenter
        markView.contentTintColor = .labelColor
        markView.toolTip = "Click to arrange icons, then hold ⌘ and drag the ┃"
        contentView = markView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `barFrame` is the divider item's window frame (AppKit coordinates); its right edge is the boundary.
    func show(atBoundary barFrame: NSRect, appearance: NSAppearance?) {
        self.appearance = appearance
        let width = StatusBarController.dividerImage.size.width
        // Sit just inside the hidden side, so the glyph never overlaps the first visible icon. The panel is
        // the full menu bar height so it's an easy click target.
        setFrame(NSRect(x: barFrame.maxX - width + 1, y: barFrame.minY, width: width, height: barFrame.height), display: true)
        orderFrontRegardless()
    }
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

/// One clickable icon in the strip. ⌘-drag it onto the menu bar to move it out of the hidden section.
final class StripItemView: NSView, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("com.controlfix.bar.strip-item")

    let item: MenuBarItem
    var onActivate: ((MenuBarItem, _ secondary: Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    /// `screenPoint` is where the mouse was released, in AppKit screen coordinates.
    var onDragEnded: ((MenuBarItem, _ screenPoint: NSPoint) -> Void)?
    private var mouseDownPoint: NSPoint = .zero
    private var isDragging = false

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    /// Captured menu bar icons are native menu-bar size (~16–22pt), which reads as tiny once
    /// blown up into the strip's own row — this baseline keeps the "Icon size" slider's 100%
    /// comfortably larger than that instead of matching it 1:1.
    private static let baseScale: CGFloat = 1.3
    /// The height every captured icon is normalized to (before `scale`) regardless of its own
    /// native/cropped size — real menu bar icons share one row height and vary only in width, but
    /// different apps capture at different native heights, so scaling each one's own size by a
    /// flat multiplier left icons visibly different sizes at the same "Icon size" setting.
    private static let referenceHeight: CGFloat = 16

    init(item: MenuBarItem, image: NSImage?, scale rawScale: CGFloat = 1, original: Bool = true) {
        self.item = item
        let scale = rawScale * Self.baseScale
        super.init(frame: .zero)
        toolTip = item.displayName
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.displayName)

        // Every icon is displayed at the same height (aspect-preserved) so a tall capture and a
        // short one read as the same size, matching how real menu bar icons share one row height.
        let imageSize: NSSize
        if let image, image.size.width > 0, image.size.height > 0 {
            // A captured picture of the real item, already padded like the menu bar.
            // "Original" shows the capture as drawn in the menu bar instead of tinting monochrome glyphs.
            if original, image.isTemplate, let copy = image.copy() as? NSImage {
                copy.isTemplate = false
                imageView.image = copy
            } else {
                imageView.image = image
            }
            imageView.imageScaling = .scaleProportionallyUpOrDown
            let displayHeight = Self.referenceHeight * scale
            imageSize = NSSize(width: displayHeight * (image.size.width / image.size.height), height: displayHeight)
        } else {
            // No picture available: show the owning app's icon.
            imageView.image = item.appIcon ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageSize = NSSize(width: 18 * scale, height: 18 * scale)
        }
        let size = NSSize(width: max(imageSize.width, 24), height: max(imageSize.height, 24))
        imageView.contentTintColor = .labelColor
        // Smooth, high-quality resampling when the capture is scaled to the strip's icon size.
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .trilinear
        imageView.layer?.minificationFilter = .trilinear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: imageSize.width),
            imageView.heightAnchor.constraint(equalToConstant: imageSize.height),
        ])
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
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), !isDragging,
              hypot(event.locationInWindow.x - mouseDownPoint.x, event.locationInWindow.y - mouseDownPoint.y) > 3
        else { return }
        isDragging = true
        isHovered = false
        onDragBegan?()
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id, forType: Self.dragType)
        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragItem.setDraggingFrame(bounds, contents: dragImage())
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // Nothing accepts the drop (the menu bar isn't a drag destination); ControlBar acts on where it ended.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// The icon on a soft pill, so it stays readable over any wallpaper while it follows the pointer.
    private func dragImage() -> NSImage {
        let appearance = effectiveAppearance
        let size = bounds.size
        let snapshot = imageView.bitmapImageRepForCachingDisplay(in: imageView.bounds)
        if let snapshot { imageView.cacheDisplay(in: imageView.bounds, to: snapshot) }
        let iconFrame = imageView.frame
        return NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            snapshot?.draw(in: iconFrame)
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        isPressed = false
        onDragEnded?(item, screenPoint)
    }

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
