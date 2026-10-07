import AppKit
import Combine
import SwiftUI

/// Owns ControlBar's three status items:
///
///     [hidden icons…] ┃  🐦⌄  ☕ [visible icons…]
///                     │   │    └ keep-awake toggle
///                     │   └ chevron: the ControlBar logo + chevron in one icon; opens the strip
///                     └ divider: grows to 10,000 pt to push everything on its left off-screen
///
/// The divider is the *only* item that pushes: whatever the user ⌘-drags to its left is hidden, no
/// matter where they put it. (An earlier design pushed with a second, invisible item that macOS never
/// kept next to the visible ┃, so icons dragged "left of the ┃" often stayed visible.)
///
/// Status items are created right-to-left, so creating keep-awake first puts the divider leftmost.
@MainActor
final class StatusBarController: NSObject {
    static let hiddenLength: CGFloat = 10_000
    static let dividerLength: CGFloat = 12
    /// Width of the divider's window once un-stretched: the item plus the status bar's side padding (measured).
    static let dividerWindowWidth: CGFloat = 28

    private let prefs: Preferences
    private let sleep: SleepPreventer
    private let keepAwakeItem: NSStatusItem
    private let chevronItem: NSStatusItem
    /// The ┃ divider. Stretches to `hiddenLength` to push everything on its left off-screen.
    private let dividerItem: NSStatusItem
    /// Draws the ┃ at the hide boundary while the strip is open (the stretched item's own glyph is off-screen).
    private let dividerMark = DividerMarkPanel()
    private var cancellables = Set<AnyCancellable>()
    /// Ticks the keep-awake countdown label while a timed session is active.
    private var countdownTimer: Timer?

    var onShowStrip: (() -> Void)?
    var onArrangingChanged: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAbout: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onInvalidOrder: (() -> Void)?
    /// Called instead of ending arrange mode directly, so pictures can be captured while icons are still visible.
    var onEndArrangingRequested: (() -> Void)?

    /// The user is ⌘-dragging icons; everything stays visible and the divider is shown.
    private(set) var isArranging = false
    /// Items are currently pushed off-screen.
    private(set) var isHidingItems = false
    /// Nested temporary reveals (e.g. while a hidden item's menu is open).
    private var revealCount = 0
    /// How many times `applyState()` has retried a hide that `isOrderValid` blocked.
    private var orderRetryAttempts = 0
    /// Guards against stacking more than one pending retry at a time.
    private var orderRetryScheduled = false
    private static let maxOrderRetries = 10

    /// True while the popup strip is open, so the ┃ is drawn at the hide boundary even though items are hidden.
    var showsDividerWhileHidden = false {
        didSet { updateDividerMark() }
    }
    /// The lime bird, pinned to the chevron button's trailing edge. It's a persistent subview
    /// rather than part of the chevron's drawn image: SF Symbols tinted with a *dynamic* colour
    /// (`.labelColor`) drawn inside a deferred `NSImage` closure silently fail to render on macOS
    /// 26's Control-Center-hosted status items (confirmed by comparing an offscreen render, where
    /// it worked, against the live menu bar, where it didn't) — so the chevron/checkmark glyph is
    /// drawn by hand with a fixed colour instead (see `chevronImage`), and the bird, which only
    /// ever uses the fixed brand lime (already proven to render fine live), stays a real subview.
    private let logoMark = NSImageView()

    private static func knobImage(brand: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 19.8, height: 19.8), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let k: CGFloat = 1.1 // 10% larger than the original 18pt glyph
            func polar(_ r: CGFloat, _ deg: CGFloat) -> NSPoint {
                NSPoint(x: c.x + r * k * cos(deg * .pi / 180), y: c.y + r * k * sin(deg * .pi / 180))
            }
            let angle: CGFloat = 50
            let dial = NSBezierPath(ovalIn: NSRect(x: c.x - 6.6 * k, y: c.y - 6.6 * k, width: 13.2 * k, height: 13.2 * k))
            if brand {
                // Same look as the app icon: navy dial with a steel ring.
                NSColor(Brand.navy).setFill()
                dial.fill()
                NSColor(red: 0x7F / 255, green: 0xA0 / 255, blue: 0xB3 / 255, alpha: 1).setStroke()
                dial.lineWidth = 1.4 * k
                dial.stroke()
            } else {
                NSColor.black.setFill()
                dial.fill()
            }
            let pointer = NSBezierPath()
            pointer.lineWidth = 1.7 * k
            pointer.lineCapStyle = .round
            pointer.move(to: polar(1.5, angle))
            pointer.line(to: polar(5.2, angle))
            if brand {
                NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).setStroke()
            } else {
                // Punch the pointer out so it reads in a monochrome (template) icon.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSColor.black.setStroke()
            }
            pointer.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let rad = angle * .pi / 180
            let nx = -sin(rad), ny = cos(rad)
            let base = polar(9, angle)
            let arrow = NSBezierPath()
            arrow.move(to: polar(7.4, angle))
            arrow.line(to: NSPoint(x: base.x + nx * 1.4 * k, y: base.y + ny * 1.4 * k))
            arrow.line(to: NSPoint(x: base.x - nx * 1.4 * k, y: base.y - ny * 1.4 * k))
            arrow.close()
            (brand ? NSColor(Brand.lime) : NSColor.black).setFill()
            arrow.fill()
            return true
        }
        image.isTemplate = !brand
        image.accessibilityDescription = "ControlBar"
        return image
    }
    private static let logoReserveWidth: CGFloat = 9.3 // knob width (19.8) + a hairline gap

    init(prefs: Preferences, sleep: SleepPreventer) {
        self.prefs = prefs
        self.sleep = sleep
        Self.seedInitialPositions()
        let bar = NSStatusBar.system
        keepAwakeItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        keepAwakeItem.autosaveName = "controlbar.keepawake"
        chevronItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        chevronItem.autosaveName = "controlbar.chevron"
        dividerItem = bar.statusItem(withLength: Self.dividerLength)
        dividerItem.autosaveName = "controlbar.divider"
        super.init()
        dividerMark.onClick = { [weak self] in self?.setArranging(true) }
        installDividerGrabMonitors()

        for (item, action) in [(keepAwakeItem, #selector(keepAwakeClicked)), (chevronItem, #selector(chevronClicked)),
                               (dividerItem, #selector(dividerClicked))] {
            item.button?.target = self
            item.button?.action = action
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // The image must stay set even while the item is stretched: an item without one stops
        // pushing anything off-screen on macOS 26. Centred in the stretched button it is off-screen.
        dividerItem.button?.image = Self.dividerImage
        dividerItem.button?.toolTip = "ControlBar divider — icons to the left of this are hidden"
        dividerItem.button?.setAccessibilityLabel("ControlBar Divider")
        chevronItem.button?.setAccessibilityLabel("ControlBar")
        keepAwakeItem.button?.setAccessibilityLabel("ControlBar Keep Awake")
        if let button = chevronItem.button {
            logoMark.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(logoMark)
            NSLayoutConstraint.activate([
                logoMark.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                logoMark.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 0),
            ])
        }

        updateChevron()
        updateKeepAwakeIcon()
        sleep.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateKeepAwakeIcon() }
            .store(in: &cancellables)
        prefs.$showKeepAwakeIcon
            .sink { [weak self] in self?.keepAwakeItem.isVisible = $0 }
            .store(in: &cancellables)
        prefs.$showLogoIcon
            .sink { [weak self] _ in self?.updateChevron() }
            .store(in: &cancellables)
        prefs.$brandColors
            .dropFirst()
            .sink { [weak self] _ in self?.updateChevron(); self?.updateKeepAwakeIcon() }
            .store(in: &cancellables)
    }

    /// New status items normally appear at the far left of the status area, which on a crowded
    /// notched MacBook is behind the notch. On first launch, place ControlBar's items at the right end
    /// instead (a preferred position is the distance from the right edge; smaller is further right).
    /// Everything else then starts out hidden, and the user ⌘-drags favourites back out.
    private static func seedInitialPositions() {
        let defaults = UserDefaults.standard
        let prefix = "NSStatusItem Preferred Position "
        // Older builds hid the divider with `isVisible = false`, which macOS remembers (and drops the item's
        // saved position for). Undo that, and slot the divider right next to the chevron.
        let dividerKey = prefix + "controlbar.divider"
        if let chevron = defaults.object(forKey: prefix + "controlbar.chevron") as? Double, defaults.object(forKey: dividerKey) == nil {
            defaults.set(chevron + 1, forKey: dividerKey)
        }
        defaults.removeObject(forKey: "NSStatusItem VisibleCC controlbar.divider")
        // Earlier builds had a separate invisible "expander" item; forget its saved state.
        defaults.removeObject(forKey: prefix + "controlbar.expander")
        defaults.removeObject(forKey: "NSStatusItem VisibleCC controlbar.expander")
        let initial: [(String, Double)] = [("controlbar.keepawake", 0), ("controlbar.chevron", 1), ("controlbar.divider", 2)]
        guard initial.allSatisfy({ defaults.object(forKey: prefix + $0.0) == nil }) else { return }
        for (name, position) in initial {
            defaults.set(position, forKey: prefix + name)
        }
    }

    // MARK: - Geometry

    /// The chevron's window, for anchoring the strip right under it.
    var chevronWindow: NSWindow? { chevronItem.button?.window }

    /// Divider frame in global top-left coordinates (the space Accessibility and CGWindowList use).
    var dividerFrameCG: CGRect? {
        guard let frame = dividerItem.button?.window?.frame else { return nil }
        return Self.toCG(frame)
    }

    var chevronFrameCG: CGRect? {
        guard let frame = chevronItem.button?.window?.frame else { return nil }
        return Self.toCG(frame)
    }

    static func toCG(_ rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Hiding is only safe when the divider sits left of the chevron; otherwise expanding it would
    /// push the chevron itself off-screen and leave no way to bring the icons back.
    private var isOrderValid: Bool {
        guard let divider = dividerItem.button?.window?.frame, let chevron = chevronItem.button?.window?.frame,
              divider.width > 0, chevron.width > 0
        else { return true }
        return divider.maxX <= chevron.minX + 1
    }

    // MARK: - Hide / reveal

    func hideItems() { applyState() }

    func setArranging(_ arranging: Bool) {
        guard arranging != isArranging else { return }
        isArranging = arranging
        applyState()
        onArrangingChanged?(arranging)
    }

    func requestEndArranging() {
        if let onEndArrangingRequested { onEndArrangingRequested() } else { setArranging(false) }
    }

    func beginTemporaryReveal() {
        revealCount += 1
        applyState()
    }

    func endTemporaryReveal() {
        revealCount = max(0, revealCount - 1)
        applyState()
    }

    private func applyState() {
        let shouldHide = !isArranging && revealCount == 0 && !grabbingDivider
        if shouldHide != isHidingItems {
            if shouldHide {
                if isOrderValid {
                    dividerItem.length = Self.hiddenLength
                    isHidingItems = true
                    orderRetryAttempts = 0
                } else {
                    retryHideAfterOrderSettles()
                }
            } else {
                dividerItem.length = Self.dividerLength
                isHidingItems = false
                orderRetryAttempts = 0
            }
        } else {
            orderRetryAttempts = 0
        }
        updateChevron()
        updateDividerMark()
    }

    /// `isOrderValid` reads the live `NSStatusItem` window frames, which AppKit is still settling
    /// asynchronously for a beat right after the four items are created at launch — so the single
    /// hide attempt fired 0.6s after launch (see `AppDelegate`) can occasionally race that settle
    /// and see a transient bad order. Before this retried, that one failed attempt was permanent:
    /// `applyState()` only runs again from an explicit trigger (arranging, a temporary reveal
    /// ending, or opening the strip), so a lost race — or an order that goes bad and then rights
    /// itself, e.g. mid-drag — left icons stuck visible in the real menu bar until the user
    /// happened to open the strip. Retry a few times over ~2s before giving up and surfacing the
    /// "drag the divider" hint, so a transient race self-heals instead of stranding the reveal.
    private func retryHideAfterOrderSettles() {
        guard orderRetryAttempts < Self.maxOrderRetries else {
            onInvalidOrder?()
            return
        }
        orderRetryAttempts += 1
        guard !orderRetryScheduled else { return }
        orderRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.orderRetryScheduled = false
            self?.applyState()
        }
    }

    /// While items are hidden the divider item is stretched and its own glyph is off-screen, so the
    /// ┃ is drawn by a click-through overlay at the boundary (the stretched item's right edge) —
    /// but only while the strip is open. Otherwise the real item's glyph is on-screen and needs no help.
    private func updateDividerMark() {
        // Changing the divider's length resizes its window a beat late (and from the wrong edge, so it can sit
        // off-screen meanwhile). Until it has settled at the boundary, leave the stand-in as it is and look
        // again, so the ┃ never blinks out or jumps to a stale spot.
        if let expected = settledBoundary, let frame = dividerItem.button?.window?.frame {
            let settled = abs(frame.maxX - expected) <= 3 && (grabbingDivider ? frame.width < 100 : frame.width > 1000)
            if !settled, settleChecks < 60 {
                // Going back to hidden: put the stand-in back at the known boundary straight away.
                if !grabbingDivider, isHidingItems, showsDividerWhileHidden, !dividerMark.isVisible {
                    dividerMark.setFrame(grabZone, display: true)
                    dividerMark.orderFrontRegardless()
                }
                settleChecks += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.updateDividerMark() }
                return
            }
            if !grabbingDivider { settledBoundary = nil }
        }
        guard isHidingItems, showsDividerWhileHidden,
              let window = dividerItem.button?.window, window.frame.width > 0
        else {
            dividerMark.orderOut(nil)
            return
        }
        dividerMark.show(atBoundary: window.frame, appearance: window.contentView?.effectiveAppearance)
    }

    /// Right edge the divider item's window should have once a length change has taken effect.
    private var settledBoundary: CGFloat?
    private var settleChecks = 0

    // MARK: - ⌘-grab of the divider while the strip is open

    /// While the strip is open the real ┃ is stretched off-screen and a click-through stand-in is drawn at
    /// the boundary. Holding ⌘ over that stand-in brings the real divider back (un-stretched, in the same
    /// spot) so a ⌘-drag grabs it with the very first press, no separate "arrange" click. It goes back to
    /// hiding once ⌘ is released or the pointer leaves, and never while a button is held (mid-drag).
    private var grabbingDivider = false {
        didSet { if grabbingDivider != oldValue { onDividerGrabChanged?(grabbingDivider) } }
    }
    /// ⌘ is held over the ┃ (real divider brought back); the strip must stay open until that ends.
    var isGrabbingDivider: Bool { grabbingDivider }
    var onDividerGrabChanged: ((Bool) -> Void)?
    private var grabZone = NSRect.zero
    private var grabMonitors: [Any] = []

    private func installDividerGrabMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .leftMouseUp, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateDividerGrab() }
        }) { grabMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.evaluateDividerGrab() }
            return event
        }) { grabMonitors.append(m) }
    }

    private func evaluateDividerGrab() {
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        let buttonDown = NSEvent.pressedMouseButtons != 0
        let mouse = NSEvent.mouseLocation
        if grabbingDivider {
            guard !buttonDown else { return }
            // Judge "still over the ┃" against the stand-in's spot, not the live item window: that window
            // is mid-resize right after the grab starts, and a stale frame made the divider drop out at once.
            if !commandHeld || !grabZone.insetBy(dx: -24, dy: -8).contains(mouse) {
                grabbingDivider = false
                settleChecks = 0
                applyState()
            }
        } else if commandHeld, !buttonDown, isHidingItems, showsDividerWhileHidden,
                  dividerMark.isVisible, dividerMark.frame.insetBy(dx: -4, dy: 0).contains(mouse) {
            grabZone = dividerMark.frame
            settledBoundary = dividerItem.button?.window?.frame.maxX
            settleChecks = 0
            grabbingDivider = true
            applyState()
        }
    }

    // MARK: - Clicks

    private var isSecondaryClick: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return event.type == .rightMouseUp || event.modifierFlags.contains(.control)
    }

    @objc private func keepAwakeClicked() {
        if isSecondaryClick {
            showMenu(from: keepAwakeItem)
        } else {
            toggleKeepAwake()
        }
    }

    @objc private func chevronClicked() {
        if isSecondaryClick {
            showMenu(from: chevronItem)
        } else if isArranging {
            requestEndArranging()
        } else if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            setArranging(true)
        } else {
            onShowStrip?()
        }
    }

    @objc private func dividerClicked() {
        showMenu(from: dividerItem)
    }

    private func showMenu(from item: NSStatusItem) {
        item.menu = buildMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - Keep awake

    func toggleKeepAwake() {
        if sleep.isActive {
            sleep.deactivate()
        } else {
            activateKeepAwake(for: prefs.defaultDuration)
        }
    }

    func activateKeepAwake(for seconds: TimeInterval) {
        sleep.activate(for: seconds > 0 ? seconds : nil, keepDisplayAwake: prefs.keepDisplayAwake)
    }

    private func updateKeepAwakeIcon() {
        // objectWillChange fires before the value changes; read it on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.keepAwakeItem.button else { return }
            let active = self.sleep.isActive
            let tint = active && self.prefs.brandColors ? NSColor(Brand.teal) : nil
            let dim = !active && !self.prefs.brandColors
            let showSeconds = self.prefs.countdownShowSeconds
            let countdown = (active ? self.sleep.endDate : nil).map { Self.countdownTitle(until: $0, showSeconds: showSeconds) }
            let image = Self.keepAwakeImage(tint: tint, dim: dim, countdown: countdown)
            image.accessibilityDescription = active ? "Keep awake on" : "Keep awake off"
            button.image = image
            button.toolTip = "Keep Awake: \(self.sleep.statusDescription)\nClick to toggle, right-click for options"

            if active, self.sleep.endDate != nil {
                self.startCountdownTimer()
            } else {
                self.stopCountdownTimer()
            }
        }
    }

    /// Remaining time. With `showSeconds`: an hour or under is "M:SS", above that "HH:MM:SS".
    /// Without it: rounded up to the next minute, "M" under an hour, "H:MM" beyond that — so the
    /// label only changes once a minute instead of every second.
    private static func countdownTitle(until endDate: Date, showSeconds: Bool) -> String {
        let secondsLeft = max(0, Int(endDate.timeIntervalSinceNow.rounded(.up)))
        guard showSeconds else {
            let minutesLeft = Int((Double(secondsLeft) / 60).rounded(.up))
            let hours = minutesLeft / 60, minutes = minutesLeft % 60
            return hours > 0 ? "\(hours):\(String(format: "%02d", minutes))" : "\(minutes)"
        }
        guard secondsLeft > 3600 else { return "\(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))" }
        let hours = secondsLeft / 3600
        let minutes = (secondsLeft % 3600) / 60
        let seconds = secondsLeft % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeepAwakeIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func updateChevron() {
        guard let button = chevronItem.button else { return }
        let showBird = prefs.showLogoIcon && !isArranging
        button.image = Self.chevronImage(arranging: isArranging, showDividerMark: false,
                                         reserveWidth: showBird ? Self.logoReserveWidth : 0)
        logoMark.image = Self.knobImage(brand: prefs.brandColors)
        logoMark.isHidden = !showBird
        button.toolTip = isArranging ? "Done arranging"
            : "ControlBar\nShow hidden icons — right-click for options, ⌥-click to arrange"
    }

    /// The chevron button's icon: an optional ┃ divider mark and the chevron (or, while arranging,
    /// a checkmark) glyph, hand-drawn with a fixed colour and `isTemplate = true` so AppKit applies
    /// the usual automatic light/dark tint itself — see `logoMark` for why this avoids drawing with
    /// a *dynamic* colour. `reserveWidth` pads the canvas so the button is wide enough to also fit
    /// `logoMark`, pinned to its trailing edge, without overlapping the next status item.
    private static func chevronImage(arranging: Bool, showDividerMark: Bool, reserveWidth: CGFloat) -> NSImage {
        let glyphWidth: CGFloat = arranging ? 14 : 10.5 // chevron is 25% smaller than the original 14×7
        let glyphHeight: CGFloat = arranging ? 14 : 5.25
        let markWidth: CGFloat = showDividerMark ? 5 : 0
        let height: CGFloat = 20 // matches the bird's rendered height, so the glyph stays centred consistently
        let size = NSSize(width: markWidth + glyphWidth + reserveWidth, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            if showDividerMark {
                NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: 2, height: height - 2), xRadius: 1, yRadius: 1).fill()
            }
            if arranging {
                let circleRect = NSRect(x: markWidth, y: (height - glyphHeight) / 2, width: glyphHeight, height: glyphHeight)
                    .insetBy(dx: 0.75, dy: 0.75)
                let circle = NSBezierPath(ovalIn: circleRect)
                circle.lineWidth = 1.3
                circle.stroke()
                let tick = NSBezierPath()
                tick.lineWidth = 1.4
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                tick.move(to: NSPoint(x: circleRect.minX + circleRect.width * 0.26, y: circleRect.midY - 0.5))
                tick.line(to: NSPoint(x: circleRect.minX + circleRect.width * 0.44, y: circleRect.minY + circleRect.height * 0.28))
                tick.line(to: NSPoint(x: circleRect.minX + circleRect.width * 0.78, y: circleRect.maxY - circleRect.height * 0.24))
                tick.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = arranging ? "Done arranging" : "Show hidden icons"
        return image
    }

    /// A crisp, vector-drawn coffee bean (no bitmap symbol exists for one), so it stays sharp at
    /// any resolution. `tint` nil draws it as a template image that follows the menu bar's
    /// light/dark appearance; a colour draws it "lit up" for the active state.
    private static let beanSize = NSSize(width: 13, height: 16)

    private static func coffeeBeanImage(tint: NSColor?, dim: Bool = false) -> NSImage {
        let image = NSImage(size: beanSize, flipped: false) { rect in
            drawBean(in: rect, tint: tint, dim: dim)
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    /// The bean, with the keep-awake countdown centred right below it — one composite bitmap so
    /// the two can never overlap or drift out of sync with each other regardless of how the
    /// status bar scales/positions the button's image.
    private static func keepAwakeImage(tint: NSColor?, dim: Bool, countdown: String?) -> NSImage {
        guard let countdown else { return coffeeBeanImage(tint: tint, dim: dim) }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let color = tint ?? NSColor.black.withAlphaComponent(dim ? 0.5 : 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (countdown as NSString).size(withAttributes: attrs)
        let gap: CGFloat = 1
        let size = NSSize(width: max(beanSize.width, textSize.width), height: beanSize.height + gap + textSize.height)
        let image = NSImage(size: size, flipped: false) { rect in
            let beanRect = NSRect(x: (rect.width - beanSize.width) / 2, y: rect.height - beanSize.height,
                                  width: beanSize.width, height: beanSize.height)
            drawBean(in: beanRect, tint: tint, dim: dim)
            let textRect = NSRect(x: (rect.width - textSize.width) / 2, y: 0, width: textSize.width, height: textSize.height)
            (countdown as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    private static func drawBean(in rect: NSRect, tint: NSColor?, dim: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let beanRect = rect.insetBy(dx: 1.5, dy: 1)
        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: beanRect, transform: nil))
        ctx.clip()
        ctx.addPath(CGPath(ellipseIn: beanRect, transform: nil))
        ctx.setFillColor((tint ?? NSColor.black.withAlphaComponent(dim ? 0.5 : 1)).cgColor)
        ctx.fillPath()

        // The bean's centre crack, cut out as a soft S-curve, clipped to the bean itself
        // so it can't bleed outside the ellipse the way an un-clipped stroke did before.
        let crack = CGMutablePath()
        crack.move(to: CGPoint(x: beanRect.midX, y: beanRect.minY + 1))
        crack.addCurve(to: CGPoint(x: beanRect.midX, y: beanRect.maxY - 1),
                       control1: CGPoint(x: beanRect.minX + beanRect.width * 0.18, y: beanRect.minY + beanRect.height * 0.38),
                       control2: CGPoint(x: beanRect.maxX - beanRect.width * 0.18, y: beanRect.minY + beanRect.height * 0.62))
        ctx.setBlendMode(.clear)
        ctx.addPath(crack)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Menu

    private var defaultDurationTitle: String {
        KeepAwakeDuration.presets.first { $0.seconds == prefs.defaultDuration }?.title.lowercased()
            ?? SleepPreventer.format(prefs.defaultDuration)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func icon(_ item: NSMenuItem, _ symbol: String) -> NSMenuItem {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        // Shortcuts (user-configurable) only work while this menu is open.
        func key(_ item: NSMenuItem, _ action: MenuShortcut) -> NSMenuItem {
            let (k, mods) = prefs.shortcut(action).menuKeyEquivalent
            item.keyEquivalent = k
            item.keyEquivalentModifierMask = mods
            return item
        }

        menu.addItem(NSMenuItem.sectionHeader(title: "Keep Awake"))
        let status = NSMenuItem(title: "Keep Awake: \(sleep.statusDescription)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(icon(status, "moon.zzz"))
        menu.addItem(icon(key(ClosureMenuItem(sleep.isActive ? "Turn Off" : "Turn On (\(defaultDurationTitle))") { [weak self] in self?.toggleKeepAwake() }, .toggle), "power"))

        let durations = NSMenu()
        for (index, preset) in KeepAwakeDuration.presets.enumerated() {
            let item = ClosureMenuItem(preset.title, key: "\(index + 1)") { [weak self] in self?.activateKeepAwake(for: preset.seconds) }
            durations.addItem(item)
        }
        let durationItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        durationItem.submenu = durations
        menu.addItem(icon(key(durationItem, .duration), "timer"))
        menu.addItem(icon(key(ClosureMenuItem("Keep Display Awake", state: prefs.keepDisplayAwake ? .on : .off) { [weak self] in
            guard let self else { return }
            self.prefs.keepDisplayAwake.toggle()
            self.sleep.setKeepDisplayAwake(self.prefs.keepDisplayAwake)
        }, .display), "display"))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "ControlBar"))
        let show = ClosureMenuItem("Show Hidden Icons") { [weak self] in self?.onShowStrip?() }
        if prefs.hotKeyEnabled {
            let (key, modifiers) = prefs.hotKey.menuKeyEquivalent
            show.keyEquivalent = key
            show.keyEquivalentModifierMask = modifiers
        }
        show.isEnabled = !isArranging
        menu.addItem(icon(show, "eye"))
        menu.addItem(icon(key(ClosureMenuItem(isArranging ? "Done Arranging" : "Arrange Menu Bar Icons…") { [weak self] in
            guard let self else { return }
            if self.isArranging { self.requestEndArranging() } else { self.setArranging(true) }
        }, .arrange), "rectangle.3.group"))
        menu.addItem(icon(key(ClosureMenuItem("Settings…") { [weak self] in self?.onOpenSettings?() }, .settings), "gearshape"))
        // Only shown while something is still missing; the menu is rebuilt each time it opens.
        if !(Permissions.accessibility && Permissions.screenRecording) {
            menu.addItem(icon(ClosureMenuItem("Permissions…") { [weak self] in self?.onOpenPermissions?() }, "lock.shield"))
        }
        menu.addItem(icon(key(ClosureMenuItem("About") { [weak self] in self?.onOpenAbout?() }, .about), "info.circle"))
        menu.addItem(.separator())
        menu.addItem(icon(key(ClosureMenuItem("Quit ControlBar") { NSApp.terminate(nil) }, .quit), "xmark.circle"))
        return menu
    }

    static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 1, y: 1, width: 2, height: rect.height - 2),
                         xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ControlBar divider"
        return image
    }()
}
