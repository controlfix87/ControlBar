import AppKit
import CoreImage

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
    private var glyphTint: NSColor?
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

    private static let ciContext = CIContext()
    private static var accentCache: [String: NSColor?] = [:]

    /// The most prominent saturated colour in the app's icon, or nil when the icon is essentially grey.
    private static func accentColor(of item: MenuBarItem) -> NSColor? {
        if let cached = accentCache[item.id] { return cached }
        let color = item.appIcon.flatMap(dominantColor)
        accentCache[item.id] = color
        return color
    }

    private static func dominantColor(of icon: NSImage) -> NSColor? {
        let n = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        // Weight pixels by saturation into hue buckets and take the heaviest bucket's average.
        var weight = [Double](repeating: 0, count: 12), sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: 12)
        for y in 0..<n { for x in 0..<n {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.6 else { continue }
            let sat = c.saturationComponent, bri = c.brightnessComponent
            guard sat > 0.4, bri > 0.3 else { continue }
            let bucket = min(11, Int(c.hueComponent * 12)), w = Double(sat * bri)
            weight[bucket] += w
            sum[bucket] = (sum[bucket].0 + Double(c.redComponent) * w, sum[bucket].1 + Double(c.greenComponent) * w, sum[bucket].2 + Double(c.blueComponent) * w)
        } }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > Double(n * n) * 0.02 else { return nil }
        let w = weight[best]
        let base = NSColor(deviceRed: sum[best].0 / w, green: sum[best].1 / w, blue: sum[best].2 / w, alpha: 1)
        // Lift it so it reads on the strip's dark and light backgrounds alike.
        return NSColor(deviceHue: base.hueComponent, saturation: min(1, base.saturationComponent), brightness: max(0.85, base.brightnessComponent), alpha: 1)
    }

    /// `image` scaled to `size` points at the screen's pixel density using a Lanczos filter.
    private static func resampled(_ image: NSImage, to size: NSSize) -> NSImage {
        let density = NSScreen.main?.backingScaleFactor ?? 2
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let targetW = max(1, (size.width * density).rounded()), targetH = max(1, (size.height * density).rounded())
        let source = CIImage(cgImage: cg)
        let scaleY = targetH / source.extent.height
        let aspect = (targetW / source.extent.width) / scaleY
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        guard let scaledOutput = filter.outputImage else { return image }
        // Enlarging a small bitmap leaves it soft; a light luminance sharpen restores the edges.
        var output = scaledOutput.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.7])
        if image.isTemplate {
            // Template glyphs are drawn from their alpha alone, and thin strokes (Time Machine's clock arrow)
            // turn into a grey haze when enlarged. Steepening the alpha ramp around 50% pulls the soft
            // edges back into crisp ones while keeping the anti-aliasing.
            let k: CGFloat = 2.2, b = 0.5 - 0.5 * k
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: b)])
        }
        guard let result = ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        else { return image }
        let scaled = NSImage(cgImage: result, size: size)
        scaled.isTemplate = image.isTemplate
        return scaled
    }

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
            imageView.imageScaling = .scaleProportionallyUpOrDown
            let density = NSScreen.main?.backingScaleFactor ?? 2
            let snap = { (v: CGFloat) in max(1, (v * density).rounded()) / density }
            let displayHeight = Self.referenceHeight * scale
            // Whole device pixels, so the bitmap lands exactly on the pixel grid instead of being stretched.
            imageSize = NSSize(width: snap(displayHeight * (image.size.width / image.size.height)), height: snap(displayHeight))
            // Resample once, with Lanczos, to the exact pixels the icon occupies on screen, so AppKit never
            // has to stretch or shrink the (oversampled) capture itself, which is what made it look soft.
            let sharp = Self.resampled(image, to: imageSize)
            if original, sharp.isTemplate {
                // Single-colour glyphs carry no colour of their own, so "colored" tints them with the owning
                // app's icon colour (falling back to the glyph as captured when the app's icon is grey).
                if let color = Self.accentColor(of: item) {
                    imageView.image = sharp
                    glyphTint = color
                } else if let copy = sharp.copy() as? NSImage {
                    copy.isTemplate = false
                    imageView.image = copy
                }
            } else {
                imageView.image = sharp
            }
        } else {
            // No picture available: show the owning app's icon.
            imageView.image = item.appIcon ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageSize = NSSize(width: 18 * scale, height: 18 * scale)
        }
        let size = NSSize(width: max(imageSize.width, 24), height: max(imageSize.height, 24))
        imageView.contentTintColor = glyphTint ?? .labelColor
        // The image is already resampled to exact pixels, so the layer must not filter it a second time.
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        imageView.layer?.minificationFilter = .nearest
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
