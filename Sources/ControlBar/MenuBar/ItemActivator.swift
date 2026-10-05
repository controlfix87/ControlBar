import AppKit
import ApplicationServices

/// Opens a hidden menu bar item on the user's behalf: briefly reveals the hidden section,
/// presses the real item (so its menu appears in the right place), then hides again once
/// the menu or popover closes.
@MainActor
final class ItemActivator {
    private let statusBar: StatusBarController
    private var isBusy = false
    /// Called after a reveal, while items are on-screen, so their pictures can be refreshed.
    var onItemsRevealed: (() -> Void)?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    /// `completion` fires exactly once, however activation ends (success, timeout, or skipped
    /// because one was already in progress) — callers rely on it to know when it's safe to hide
    /// whatever UI they used to trigger this (see `StripController`, which keeps its strip on
    /// screen until this fires instead of hiding it the instant the item is clicked).
    func activate(_ item: MenuBarItem, secondary: Bool, completion: (() -> Void)? = nil) {
        guard !isBusy else {
            completion?()
            return
        }
        isBusy = true
        NSLog("ControlBar DIAG: activate start item=\(item.displayName) secondary=\(secondary)")
        Task { @MainActor in
            defer {
                isBusy = false
                NSLog("ControlBar DIAG: activate end item=\(item.displayName)")
                completion?()
            }
            let baseline = Self.overlayWindowIDs()
            statusBar.beginTemporaryReveal()
            NSLog("ControlBar DIAG: beginTemporaryReveal baselineCount=\(baseline.count)")
            defer { statusBar.endTemporaryReveal(); NSLog("ControlBar DIAG: endTemporaryReveal") }

            guard let frame = await waitUntilOnScreen(item) else {
                NSLog("ControlBar: \(item.displayName) did not become visible")
                return
            }
            NSLog("ControlBar DIAG: onScreen frame=\(frame)")
            onItemsRevealed?()
            await press(item, frame: frame, secondary: secondary, baseline: baseline)
            await waitForMenusToClose(baseline: baseline)
        }
    }

    // MARK: - Moving an item out of the hidden section

    enum MoveResult {
        case moved
        /// The item can't be grabbed while revealed (most likely it sits behind the notch, or off the left edge).
        case unreachable
        case failed
    }

    /// Moves a hidden item to the menu bar at `dropX` (global top-left coordinates) by doing what the user
    /// would: reveal the hidden section, then ⌘-drag the real item there. macOS has no API for moving other
    /// apps' status items, so a synthetic ⌘-drag is the only way. `completion` fires exactly once.
    func moveToMenuBar(_ item: MenuBarItem, dropX: CGFloat, completion: @escaping (MoveResult) -> Void) {
        guard !isBusy else {
            completion(.failed)
            return
        }
        isBusy = true
        Task { @MainActor in
            // Everything right of the divider keeps its position when the hidden section is revealed
            // (the bar is right-anchored), so the drop point stays valid across the reveal.
            let boundary = statusBar.dividerFrameCG?.maxX ?? 0
            var result = MoveResult.failed
            // First try without revealing anything: a ⌘-drag posted at the session level and addressed
            // to the item's window works even while that window is pushed off-screen. This is the only
            // way to move an icon that would sit behind the notch (or off the left edge) when revealed.
            if let frame = AX.frame(item.element) {
                let target = CGPoint(x: max(dropX, boundary + 4), y: frame.midY)
                await Self.commandDragInPlace(item, from: CGPoint(x: frame.midX, y: frame.midY), to: target)
                if await didLand(item, rightOf: boundary) { result = .moved }
                NSLog("ControlBar: moved \(item.displayName) in place from \(frame) to x=\(target.x): \(result)")
            }
            if result != .moved {
                // Fallback: reveal the hidden section and drag the icon like a user would.
                statusBar.beginTemporaryReveal()
                if let frame = await waitUntilReachable(item) {
                    let target = CGPoint(x: max(dropX, boundary + 4), y: frame.midY)
                    await Self.commandDrag(from: CGPoint(x: frame.midX, y: frame.midY), to: target)
                    result = await didLand(item, rightOf: boundary) ? .moved : .failed
                    NSLog("ControlBar: moved \(item.displayName) from \(frame) to x=\(target.x): \(result)")
                } else {
                    result = .unreachable
                    NSLog("ControlBar: \(item.displayName) can't be reached while revealed")
                }
                statusBar.endTemporaryReveal()
            }
            isBusy = false
            completion(result)
        }
    }

    /// Hands the user's in-progress drag (pointer at `point`, global top-left coordinates) over to the
    /// real item, so macOS runs its own live ⌘-drag on it from here. Returns false, having done nothing,
    /// when that isn't possible; the caller then falls back to `moveToMenuBar` when the drag ends.
    /// `onEnded` fires once, when the user lets go.
    func beginLiveDrag(_ item: MenuBarItem, at point: CGPoint, onEnded: @escaping () -> Void) -> Bool {
        guard !isBusy else { return false }
        let windows = MenuBarScanner.statusWindows()
        let center = AX.frame(item.element).map { CGPoint(x: $0.midX, y: $0.midY) }
        let window = item.windowID.flatMap { id in windows.first { $0.id == id } }
            ?? center.flatMap { c in windows.first { $0.frame.width < 1000 && $0.frame.contains(c) } }
        guard let window else { return false }
        let started = LiveDragTap.shared.begin(window: window, at: point) { [weak self] in
            self?.isBusy = false
            NSLog("ControlBar: live drag of \(item.displayName) ended at \(AX.frame(item.element).map { "\($0)" } ?? "?")")
            onEnded()
        }
        if started {
            isBusy = true
            NSLog("ControlBar: live drag of \(item.displayName) started at \(point)")
        }
        return started
    }

    /// ⌘-drags an item to `end` without it having to be on-screen. The events go in at the session level
    /// and name the item's window explicitly, so the window server delivers them to that window wherever
    /// it is; the HID-level drag in `commandDrag` can't do this, because the pointer can't reach a window
    /// that is off-screen or not drawn (behind the notch).
    private static func commandDragInPlace(_ item: MenuBarItem, from start: CGPoint, to end: CGPoint) async {
        let windows = MenuBarScanner.statusWindows()
        let startWindow = item.windowID.flatMap { id in windows.first { $0.id == id } }
            ?? windows.first { $0.frame.width < 1000 && $0.frame.contains(start) }
        guard let startWindow else { return }
        let endWindow = windows.first { $0.isOnScreen && $0.frame.contains(end) }
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, _ point: CGPoint, _ window: StatusWindow) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = .maskCommand
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: LiveDragTap.eventTag)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(window.ownerPID))
            // Undocumented window-ID field the window server uses to route the event (same trick as Ice).
            if let field = CGEventField(rawValue: 0x33) { event.setIntegerValueField(field, value: Int64(window.id)) }
            event.post(tap: .cgSessionEventTap)
        }
        post(.leftMouseDown, start, startWindow)
        try? await Task.sleep(for: .milliseconds(100))
        post(.leftMouseDragged, end, startWindow)
        try? await Task.sleep(for: .milliseconds(100))
        post(.leftMouseUp, end, endWindow ?? startWindow)
        if let original { CGWarpMouseCursorPosition(original) }
    }

    /// The item is on-screen and actually drawn (icons behind the notch report a frame but aren't).
    private func waitUntilReachable(_ item: MenuBarItem) async -> CGRect? {
        let screens = NSScreen.screens.map { StatusBarController.toCG($0.frame) }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(40))
            guard let frame = AX.frame(item.element),
                  screens.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            else { continue }
            let drawn = item.windowID.map { id in MenuBarScanner.statusWindows().first { $0.id == id }?.isOnScreen ?? false } ?? true
            if drawn {
                try? await Task.sleep(for: .milliseconds(80)) // let the layout animation finish
                return AX.frame(item.element) ?? frame
            }
        }
        return nil
    }

    private func didLand(_ item: MenuBarItem, rightOf boundary: CGFloat) async -> Bool {
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(80))
            if let frame = AX.frame(item.element), frame.minX >= boundary { return true }
        }
        return false
    }

    /// Posts one mouse event. The window server routes status-item clicks and drags by the window under
    /// the pointer, so the event is tagged with the item's window; an untagged drag does nothing, and an
    /// untagged click never reaches an item hidden behind the notch.
    private static func postMouse(_ type: CGEventType, button: CGMouseButton, at point: CGPoint,
                                  flags: CGEventFlags = [], window: StatusWindow?, source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        if let window {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.id))
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(window.ownerPID))
        }
        event.post(tap: .cghidEventTap)
    }

    /// A left-button drag with ⌘ held, which is how macOS lets you rearrange menu bar icons.
    private static func commandDrag(from start: CGPoint, to end: CGPoint) async {
        let windows = MenuBarScanner.statusWindows().filter { $0.isOnScreen }
        func window(at point: CGPoint) -> StatusWindow? { windows.first { $0.frame.contains(point) } }
        let startWindow = window(at: start)
        let endWindow = window(at: end)
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, _ point: CGPoint, _ target: StatusWindow?) {
            postMouse(type, button: .left, at: point, flags: .maskCommand, window: target, source: source)
        }
        post(.mouseMoved, start, startWindow)
        try? await Task.sleep(for: .milliseconds(80))
        post(.leftMouseDown, start, startWindow)
        try? await Task.sleep(for: .milliseconds(150))
        let steps = 24
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(.leftMouseDragged, point, startWindow)
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(200))
        post(.leftMouseUp, end, endWindow ?? startWindow)
        if let original { CGWarpMouseCursorPosition(original) }
    }

    // MARK: - Steps

    /// After the divider shrinks the item slides back on-screen; poll its position until it lands.
    private func waitUntilOnScreen(_ item: MenuBarItem) async -> CGRect? {
        let screens = NSScreen.screens.map { StatusBarController.toCG($0.frame) }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(40))
            if let frame = AX.frame(item.element),
               screens.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
                // One extra beat so the menu bar finishes its layout animation.
                try? await Task.sleep(for: .milliseconds(60))
                return AX.frame(item.element) ?? frame
            }
        }
        return nil
    }

    /// `AXUIElement` isn't `Sendable`, but the AX calls made with it are thread-safe.
    private struct ElementBox: @unchecked Sendable { let element: AXUIElement }

    /// Opens the item's menu or popover: an Accessibility action when the item has one, otherwise a
    /// synthetic click.
    ///
    /// The AX action is fired on a background thread and judged by whether a menu window actually shows
    /// up, never by its return value. Apps run their menu-tracking loop *inside* the action handler, so
    /// the call blocks until the menu closes (or times out, ~1.5 s) and then reports failure even though
    /// the menu opened. Trusting that result — or blocking the main thread on it — used to trigger the
    /// synthetic-click fallback on top of the just-opened menu, which dismissed it.
    private func press(_ item: MenuBarItem, frame: CGRect, secondary: Bool, baseline: Set<CGWindowID>) async {
        let actions = AX.actions(item.element)
        let window = item.windowID.flatMap { id in MenuBarScanner.statusWindows().first { $0.id == id } }
        // A synthetic click can only reach an icon that is actually drawn; one behind the notch has to
        // go through Accessibility, even for a right-click (its menu is usually the same one).
        let isDrawn = window?.isOnScreen ?? true

        var action: String?
        if secondary {
            if actions.contains(kAXShowMenuAction) { action = kAXShowMenuAction }
            else if !isDrawn, actions.contains(kAXPressAction) { action = kAXPressAction }
        } else if actions.contains(kAXPressAction) {
            action = kAXPressAction
        }
        NSLog("ControlBar DIAG: press secondary=\(secondary) action=\(action ?? "synthetic click") drawn=\(isDrawn)")

        if let action {
            let box = ElementBox(element: item.element)
            Task.detached { _ = AX.perform(box.element, action) }
            // Generous window before assuming nothing opened: a synthetic click on top of a menu that
            // *did* open (just slowly) lands on it or on the wrong entry. Waiting a little too long is
            // harmless; a wrong fallback click is not.
            for i in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if !Self.overlayWindowIDs().subtracting(baseline).isEmpty {
                    NSLog("ControlBar DIAG: press saw overlay after \((i + 1) * 100)ms via AX")
                    return
                }
            }
            NSLog("ControlBar DIAG: press: no overlay 3s after AX action, falling back to synthetic click")
        }
        guard isDrawn else { return }
        // Re-fetch the position rather than trusting the frame captured before the wait above; if the bar
        // reflowed meanwhile, a stale point can land on a neighbour and open the wrong menu.
        let clickFrame = AX.frame(item.element) ?? frame
        NSLog("ControlBar DIAG: synthetic click at \(clickFrame) (original frame was \(frame))")
        await Self.click(at: CGPoint(x: clickFrame.midX, y: clickFrame.midY), secondary: secondary, window: window)
    }

    /// Falls back to a synthetic click when the item doesn't support the Accessibility action.
    private static func click(at point: CGPoint, secondary: Bool, window: StatusWindow?) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = secondary
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)
        postMouse(.mouseMoved, button: button, at: point, window: window, source: source)
        try? await Task.sleep(for: .milliseconds(50))
        postMouse(down, button: button, at: point, window: window, source: source)
        try? await Task.sleep(for: .milliseconds(60)) // a real click isn't instantaneous
        postMouse(up, button: button, at: point, window: window, source: source)
        if let original { CGWarpMouseCursorPosition(original) }
    }

    /// Keeps the section revealed while a new menu/popover window is on screen.
    ///
    /// Every wait here re-checks for an overlay before giving up — a blind "wait a bit then bail"
    /// grace period would risk collapsing the reveal (and killing the item's own menu-tracking
    /// loop, which macOS dismisses when its status item vanishes) right as a slow-to-open menu
    /// finally appears.
    private func waitForMenusToClose(baseline: Set<CGWindowID>) async {
        // Give the item a moment to open something — some apps are slow to post their menu.
        var sawOverlay = false
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            if !Self.overlayWindowIDs().subtracting(baseline).isEmpty { sawOverlay = true; break }
        }
        guard sawOverlay else {
            NSLog("ControlBar DIAG: waitForMenusToClose never saw an overlay, returning")
            return
        }
        NSLog("ControlBar DIAG: waitForMenusToClose saw overlay, waiting for it to close")
        // Wait (up to a minute) until every new overlay window is gone.
        var closed = false
        for _ in 0..<(60 * 4) {
            try? await Task.sleep(for: .milliseconds(250))
            if Self.overlayWindowIDs().subtracting(baseline).isEmpty { closed = true; break }
        }
        NSLog("ControlBar DIAG: waitForMenusToClose done, closed=\(closed) (false means we hit the 1-minute cap)")
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// On-screen windows above normal level that look like menus or popovers (not menu bar strips).
    static func overlayWindowIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let screenTops = NSScreen.screens.map { StatusBarController.toCG($0.frame).minY }
        var ids = Set<CGWindowID>()
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= statusLevel - 1, layer < 1000,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // Skip the menu bar itself and status items: short windows hugging a screen's top edge.
            let isMenuBarStrip = bounds.height <= 50 && screenTops.contains { abs($0 - bounds.minY) < 2 }
            if !isMenuBarStrip { ids.insert(id) }
        }
        return ids
    }
}
