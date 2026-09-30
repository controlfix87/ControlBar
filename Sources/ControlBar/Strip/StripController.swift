import AppKit
import Combine

/// Shows hidden menu bar items in a strip right under the menu bar, and hides it again
/// after a delay, on a click outside, on Escape, or when the space/screen changes.
@MainActor
final class StripController {
    private enum Content {
        case items([MenuBarItem], [String: NSImage])
        case message(String, button: (title: String, action: () -> Void)?)
    }

    private let prefs: Preferences
    private let statusBar: StatusBarController
    private let capturer: ItemImageCapturer
    private let activator: ItemActivator
    private let panel = StripPanel()

    private var hideTimer: Timer?
    private var pendingHideTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isHovering = false
    /// A strip icon is being ⌘-dragged out; the strip must not auto-hide from under it.
    private var isDragging = false
    private var loadGeneration = 0
    private(set) var isVisible = false
    /// Opens ControlBar's own Settings on the Permissions tab.
    var onOpenPermissions: (() -> Void)?
    /// True while hidden icons are revealed inline in the real menu bar instead of the popup strip.
    private var isInlineReveal = false
    /// The notch-safe left boundary used by `hasRoomForInlineReveal`, cached per physical display —
    /// it only depends on the screen's own geometry (its notch, if any), which doesn't change at
    /// runtime, so there's no need to re-derive it on every click.
    private var leftBoundaryCache: [CGDirectDisplayID: CGFloat] = [:]

    init(prefs: Preferences, statusBar: StatusBarController, capturer: ItemImageCapturer, activator: ItemActivator) {
        self.prefs = prefs
        self.statusBar = statusBar
        self.capturer = capturer
        self.activator = activator
        prewarmInlineRevealGeometry()
        // The built-in display's geometry never changes at runtime, but plugging/unplugging an
        // external one can; re-warm rather than trust a stale cache entry after that happens.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.leftBoundaryCache.removeAll()
                self?.prewarmInlineRevealGeometry()
            }
        }
    }

    // MARK: - Public

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard Permissions.accessibility else {
            present(.message("ControlBar needs Accessibility permission to find and open hidden menu bar icons.",
                             button: ("Grant Access…", { [weak self] in self?.onOpenPermissions?() })))
            return
        }
        if !statusBar.isHidingItems && !statusBar.isArranging {
            statusBar.hideItems()
        }
        guard statusBar.isHidingItems, let divider = statusBar.dividerFrameCG else {
            present(.message("Icons aren't hidden right now. Make sure the ┃ divider is to the left of ControlBar's ⌄ icon (hold ⌘ and drag it).",
                             button: ("Arrange…", { [weak self] in self?.statusBar.setArranging(true) })))
            return
        }

        statusBar.showsDividerWhileHidden = true
        loadGeneration += 1
        let generation = loadGeneration
        let apps = MenuBarScanner.runningApps()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        Task { @MainActor in
            let all = await Task.detached { MenuBarScanner.scan(apps: apps, excludingPID: ownPID) }.value
            let hidden = MenuBarScanner.hidden(all, dividerFrame: divider)
            guard generation == self.loadGeneration else { return }

            if !hidden.isEmpty, self.prefs.preferInlineReveal, self.hasRoomForInlineReveal(hidden, divider: divider) {
                self.statusBar.beginTemporaryReveal()
                self.beginInlineSession()
                return
            }

            // Show right away with whatever pictures are cached, then refresh them.
            self.present(self.itemsOrEmpty(hidden, images: self.capturer.cache))
            let images = await self.capturer.images(for: hidden)
            guard generation == self.loadGeneration, self.isVisible else { return }
            self.present(self.itemsOrEmpty(hidden, images: images))
        }
    }

    /// Decides, from geometry alone, whether the hidden items would fit back in the real menu bar —
    /// so the choice between inline reveal and the popup strip is made once, up front, on the same
    /// click that opens it, instead of speculatively revealing and then correcting a beat later
    /// (which read as the strip flashing open behind an inline reveal that had to be undone).
    ///
    /// A live on-screen check (e.g. `kCGWindowIsOnscreen` after actually revealing) would be more
    /// exact, but only after the fact. This estimates the same thing beforehand: the free width
    /// between the notch's safe area (or the screen edge, if there's no notch) and where ControlBar's
    /// own items start, versus the hidden items' combined width.
    private func hasRoomForInlineReveal(_ items: [MenuBarItem], divider: CGRect) -> Bool {
        guard let screen = statusBar.chevronWindow?.screen else { return false }
        let margin: CGFloat = 8 // breathing room, plus the divider's own (small) width once shrunk back
        let available = divider.minX - leftBoundary(for: screen) - margin
        let interItemGap: CGFloat = 2
        let needed = items.reduce(0) { $0 + $1.frame.width } + CGFloat(max(0, items.count - 1)) * interItemGap
        return needed <= available
    }

    /// Precomputes and caches `hasRoomForInlineReveal`'s screen-geometry half, so the click itself
    /// never has to touch `NSScreen` at all. Cheap to call speculatively — e.g. on hover, before
    /// the user has even clicked — since it only reads static display geometry.
    func prewarmInlineRevealGeometry() {
        for screen in NSScreen.screens { _ = leftBoundary(for: screen) }
    }

    private func leftBoundary(for screen: NSScreen) -> CGFloat {
        let id = CGDirectDisplayID(truncating: screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber ?? 0)
        if let cached = leftBoundaryCache[id] { return cached }
        let value = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.minX
        leftBoundaryCache[id] = value
        return value
    }

    private func beginInlineSession() {
        isVisible = true
        isInlineReveal = true
        isHovering = false
        installMonitors()
        restartHideTimer()
    }

    /// Shows a short explanatory message in the strip's place.
    func showHint(_ text: String) {
        present(.message(text, button: nil))
    }

    func hide(animated: Bool = true) {
        pendingHideTask?.cancel()
        pendingHideTask = nil
        guard isVisible else { return }
        isVisible = false
        let wasInline = isInlineReveal
        isInlineReveal = false
        statusBar.showsDividerWhileHidden = false
        loadGeneration += 1
        hideTimer?.invalidate()
        hideTimer = nil
        removeMonitors()
        isHovering = false
        if wasInline {
            statusBar.endTemporaryReveal()
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible else { return }
                    self.panel.orderOut(nil)
                }
            })
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Content

    private func itemsOrEmpty(_ items: [MenuBarItem], images: [String: NSImage]) -> Content {
        if items.isEmpty {
            return .message("No hidden icons yet. Hold ⌘ and drag menu bar icons to the left of the ┃ divider to hide them.",
                            button: ("Arrange…", { [weak self] in self?.statusBar.setArranging(true) }))
        }
        return .items(items, images)
    }

    private func present(_ content: Content) {
        let background = StripBackgroundView()
        background.onHoverChanged = { [weak self] hovering in self?.hoverChanged(hovering) }
        let body = makeBody(content)
        body.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            body.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            body.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            body.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        // Match the menu bar's light/dark look: captured icons were drawn for it.
        panel.appearance = statusBar.chevronWindow?.contentView?.effectiveAppearance
        panel.contentView = background
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize
        let frame = targetFrame(for: size)

        if isVisible {
            panel.setFrame(frame, display: true)
        } else {
            isVisible = true
            statusBar.showsDividerWhileHidden = true
            panel.alphaValue = 0
            panel.setFrame(frame.offsetBy(dx: 0, dy: 6), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
            installMonitors()
        }
        // The hover state belongs to the old view; re-derive it from the mouse position.
        isHovering = frame.contains(NSEvent.mouseLocation)
        restartHideTimer(for: content)
    }

    private func makeBody(_ content: Content) -> NSView {
        switch content {
        case let .items(items, images):
            let views = items.map { item -> NSView in
                let view = StripItemView(item: item, image: images[item.id], scale: CGFloat(prefs.stripScale))
                view.onActivate = { [weak self] item, secondary in
                    // Keep the strip visible through the activation instead of yanking it away
                    // the instant the item is clicked — the real reveal-and-press still has to
                    // happen behind it (that's the only way to show the item's real menu), but
                    // the strip itself only disappears once that's actually finished.
                    self?.activator.activate(item, secondary: secondary) { [weak self] in
                        self?.hide(animated: false)
                    }
                }
                view.onDragBegan = { [weak self] in self?.dragBegan() }
                view.onDragEnded = { [weak self] item, point in self?.dragEnded(item, at: point) }
                return view
            }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 0
            stack.alignment = .centerY
            return stack

        case let .message(text, button):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 300
            var views: [NSView] = [label]
            if let button {
                let control = ActionButton(title: button.title) { [weak self] in
                    self?.hide(animated: false)
                    button.action()
                }
                control.bezelStyle = .rounded
                control.controlSize = .small
                views.append(control)
            }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.alignment = .centerY
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 4)
            return stack
        }
    }

    // MARK: - Dragging icons out

    private func dragBegan() {
        isDragging = true
        hideTimer?.invalidate()
        hideTimer = nil
        pendingHideTask?.cancel()
        pendingHideTask = nil
    }

    /// An icon was ⌘-dragged out of the strip. If it was let go over the menu bar (right of the ┃), move
    /// the real icon there; anywhere else it's a cancelled drag and the strip carries on.
    private func dragEnded(_ item: MenuBarItem, at screenPoint: NSPoint) {
        isDragging = false
        let point = StatusBarController.toCG(NSRect(origin: screenPoint, size: .zero)).origin
        // Anywhere on the bar counts. The bar is right-anchored, so a drop left of the first visible icon
        // (the empty area) means "make it the leftmost visible icon"; `moveToMenuBar` clamps the x for that.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }),
              !panel.frame.contains(screenPoint), isOverMenuBar(screenPoint, on: screen)
        else {
            restartHideTimer()
            return
        }
        hide(animated: false)
        activator.moveToMenuBar(item, dropX: point.x) { [weak self] result in
            switch result {
            case .moved: break
            case .unreachable:
                self?.showHint("\(item.displayName) is behind the notch (or off-screen) while the hidden icons are revealed, so it can't be dragged out from here. Move it from the menu bar itself, or make more room by hiding fewer icons.")
            case .failed:
                self?.showHint("Couldn't move \(item.displayName). Make sure ControlBar has Accessibility access, then try again.")
            }
        }
    }

    private func isOverMenuBar(_ point: NSPoint, on screen: NSScreen) -> Bool {
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // A little slack below the bar: the pointer is often let go just under it, next to the strip.
        return screen.frame.maxY - point.y <= max(barHeight, 24) + 10
    }

    /// Right-aligned under the chevron, just below the menu bar, clamped to the screen.
    private func targetFrame(for size: NSSize) -> NSRect {
        let gap: CGFloat = 5
        let anchorWindow = statusBar.chevronWindow
        let screen = anchorWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        var anchor = anchorWindow?.frame ?? .zero
        if !screen.frame.intersects(anchor) {
            // Fall back to the top-right corner, under the menu bar.
            anchor = NSRect(x: screen.frame.maxX - 60, y: screen.visibleFrame.maxY, width: 40, height: 0)
        }
        var x = anchor.maxX - size.width + 8
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let y = anchor.minY - gap - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Auto-hide

    private func restartHideTimer(for content: Content? = nil) {
        hideTimer?.invalidate()
        hideTimer = nil
        if isDragging || (isHovering && prefs.pauseWhileHovering) { return }
        var delay = prefs.autoHideDelay
        if case .message = content { delay = max(delay, 8) }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAfterMenusClose() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    /// Hides, but if the triggering click just opened a menu/popover (e.g. a right-click on an
    /// inline-revealed icon, which macOS handles directly and we never see), waits for it to close
    /// first instead of yanking the icon — and the menu with it — out from under the user.
    ///
    /// This first *polls* for an overlay to show up at all (some apps, LuLu among them, are slow
    /// to post their menu) before it waits for one to close. A single check after one fixed grace
    /// period isn't enough — it can run before a slow menu has appeared and hide (dismissing) it
    /// right out from under the user. The poll is capped well under a second so the common case
    /// (a plain click elsewhere, no menu involved at all) doesn't pick up a noticeable delay.
    ///
    /// Both checks only count overlays that are *new* since this was triggered (subtracting
    /// `baseline`) and the close-wait has a hard ceiling — otherwise a window that was already
    /// on screen for an unrelated reason (or a menu macOS never reports as closed) reads as "a
    /// menu is still open" forever, permanently stranding the reveal.
    private func hideAfterMenusClose() {
        guard !isDragging else { return }
        pendingHideTask?.cancel()
        let baseline = ItemActivator.overlayWindowIDs()
        NSLog("ControlBar DIAG: hideAfterMenusClose called, baselineCount=\(baseline.count)")
        pendingHideTask = Task { @MainActor [weak self] in
            var sawOverlay = false
            for _ in 0..<5 {
                guard !Task.isCancelled else { return }
                if !ItemActivator.overlayWindowIDs().subtracting(baseline).isEmpty { sawOverlay = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            NSLog("ControlBar DIAG: hideAfterMenusClose sawOverlay=\(sawOverlay)")
            if sawOverlay {
                var closed = false
                for _ in 0..<(60 * 5) {
                    if ItemActivator.overlayWindowIDs().subtracting(baseline).isEmpty { closed = true; break }
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                }
                NSLog("ControlBar DIAG: hideAfterMenusClose wait done, closed=\(closed)")
            }
            guard !Task.isCancelled else { return }
            NSLog("ControlBar DIAG: hideAfterMenusClose calling hide()")
            self.hide()
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        guard prefs.pauseWhileHovering else { return }
        if hovering {
            hideTimer?.invalidate()
            hideTimer = nil
        } else {
            restartHideTimer()
        }
    }

    private func installMonitors() {
        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.prefs.hideOnClickOutside else { return }
                self.hideAfterMenusClose()
            }
        }) { monitors.append(m) }
        // Clicks in ControlBar's own windows other than the strip (the chevron toggles on its own).
        if let m = NSEvent.addLocalMonitorForEvents(matching: clickMask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.prefs.hideOnClickOutside,
                      event.window !== self.panel, event.window !== self.statusBar.chevronWindow
                else { return }
                self.hideAfterMenusClose()
            }
            return event
        }) { monitors.append(m) }
        // Escape, wherever the focus is (global key monitoring relies on Accessibility access).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }) { monitors.append(m) }

        let hideNow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: hideNow))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: hideNow))
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
    }
}

/// `NSButton` with a closure action.
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}
