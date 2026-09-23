import AppKit
import ApplicationServices

/// One status item (menu bar extra) belonging to some app.
struct MenuBarItem: Identifiable {
    /// Stable-ish key used for caching images between scans.
    let id: String
    let pid: pid_t
    let appName: String
    let bundleID: String?
    /// Accessibility description/title of the item (e.g. "Wi-Fi"); may be empty.
    let label: String
    /// Frame in global top-left-origin coordinates, as reported by Accessibility.
    let frame: CGRect
    /// The window-server window drawing this item, used for capturing its picture.
    let windowID: CGWindowID?
    let element: AXUIElement

    var displayName: String {
        if label.isEmpty || label == appName { return appName }
        return "\(appName) — \(label)"
    }

    var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

/// A window at the status-item level, straight from the window server.
struct StatusWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let frame: CGRect
    let isOnScreen: Bool
}

/// Finds menu bar items. Accessibility supplies the owning app, label, position and a
/// pressable element; the window list supplies the window ID used for screenshots.
/// (On macOS 26 every status-item window is owned by Control Center, so the window
/// list alone can't tell which app an item belongs to.)
enum MenuBarScanner {
    struct AppRef {
        let pid: pid_t
        let name: String
        let bundleID: String?
    }

    /// Snapshot of running apps; take it on the main thread.
    @MainActor
    static func runningApps() -> [AppRef] {
        NSWorkspace.shared.runningApplications.map {
            AppRef(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)",
                   bundleID: $0.bundleIdentifier)
        }
    }

    /// All menu bar items of all apps, left to right. Safe to call off the main thread.
    static func scan(apps: [AppRef], excludingPID: pid_t? = nil) -> [MenuBarItem] {
        let windows = statusWindows()
        var items: [MenuBarItem] = []
        for app in apps where app.pid != excludingPID {
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            guard let extras = AX.element(appElement, kAXExtrasMenuBarAttribute) else { continue }
            let children = AX.children(extras)
            var seenLabels: [String: Int] = [:]
            for (index, child) in children.enumerated() {
                guard let frame = AX.frame(child), frame.width > 0 else { continue }
                let label = AX.string(child, kAXDescriptionAttribute)
                    ?? AX.string(child, kAXTitleAttribute)
                    ?? AX.string(child, kAXHelpAttribute)
                    ?? AX.string(child, kAXIdentifierAttribute)
                    ?? ""
                let owner = app.bundleID ?? app.name
                let dup = seenLabels[label, default: 0]
                seenLabels[label] = dup + 1
                let key = label.isEmpty ? "\(owner)#\(index)" : "\(owner)#\(label)#\(dup)"
                items.append(MenuBarItem(id: key, pid: app.pid, appName: app.name, bundleID: app.bundleID,
                                         label: label, frame: frame,
                                         windowID: matchWindow(for: frame, pid: app.pid, in: windows),
                                         element: child))
            }
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Items sitting to the left of the divider on the divider's menu bar.
    static func hidden(_ items: [MenuBarItem], dividerFrame: CGRect) -> [MenuBarItem] {
        items.filter {
            $0.frame.maxX <= dividerFrame.minX + 2 && abs($0.frame.midY - dividerFrame.midY) < 30
        }
    }

    static func statusWindows() -> [StatusWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let number = w[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return StatusWindow(id: number,
                                ownerPID: w[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                                ownerName: w[kCGWindowOwnerName as String] as? String ?? "?",
                                frame: bounds,
                                isOnScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    /// Accessibility reports the button's frame, which can be narrower than its window
    /// (e.g. square items), so match on the window that contains the button's center.
    private static func matchWindow(for frame: CGRect, pid: pid_t, in windows: [StatusWindow]) -> CGWindowID? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let candidates = windows.filter { $0.frame.insetBy(dx: -1, dy: -1).contains(center) }
        return (candidates.first { $0.ownerPID == pid } ?? candidates.first)?.id
    }
}
