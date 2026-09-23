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

    func activate(_ item: MenuBarItem, secondary: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            let baseline = Self.overlayWindowIDs()
            statusBar.beginTemporaryReveal()
            defer { statusBar.endTemporaryReveal() }

            guard let frame = await waitUntilOnScreen(item) else {
                NSLog("ControlBar: \(item.displayName) did not become visible")
                return
            }
            onItemsRevealed?()
            press(item, frame: frame, secondary: secondary)
            await waitForMenusToClose(baseline: baseline)
        }
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

    private func press(_ item: MenuBarItem, frame: CGRect, secondary: Bool) {
        let action = secondary ? kAXShowMenuAction : kAXPressAction
        if AX.actions(item.element).contains(action), AX.perform(item.element, action) {
            return
        }
        Self.click(at: CGPoint(x: frame.midX, y: frame.midY), secondary: secondary)
    }

    /// Falls back to a synthetic click when the item doesn't support the Accessibility action.
    private static func click(at point: CGPoint, secondary: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = secondary
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        if let original { CGWarpMouseCursorPosition(original) }
    }

    /// Keeps the section revealed while a new menu/popover window is on screen.
    private func waitForMenusToClose(baseline: Set<CGWindowID>) async {
        // Give the item a moment to open something.
        var sawOverlay = false
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            if !Self.overlayWindowIDs().subtracting(baseline).isEmpty { sawOverlay = true; break }
        }
        guard sawOverlay else {
            try? await Task.sleep(for: .milliseconds(600))
            return
        }
        // Wait (up to 10 minutes) until every new overlay window is gone.
        for _ in 0..<(10 * 60 * 4) {
            try? await Task.sleep(for: .milliseconds(250))
            if Self.overlayWindowIDs().subtracting(baseline).isEmpty { break }
        }
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
