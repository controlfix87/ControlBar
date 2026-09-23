import AppKit

/// Plain-text report of what ControlBar sees in the menu bar; handy for bug reports.
@MainActor
enum Diagnostics {
    static func report(statusBar: StatusBarController, capturer: ItemImageCapturer, imageDirectory: URL? = nil) async -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        lines.append("ControlBar \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Accessibility: \(Permissions.accessibility)   Screen Recording: \(Permissions.screenRecording)")
        lines.append("Hiding items: \(statusBar.isHidingItems)   Arranging: \(statusBar.isArranging)")
        for screen in NSScreen.screens {
            lines.append("Screen \(screen.localizedName): frame=\(fmt(screen.frame)) visible=\(fmt(screen.visibleFrame)) safeTop=\(screen.safeAreaInsets.top)")
        }
        lines.append("Divider (CG): \(statusBar.dividerFrameCG.map(fmt) ?? "nil")")
        lines.append("Chevron (CG): \(statusBar.chevronFrameCG.map(fmt) ?? "nil")")

        let apps = MenuBarScanner.runningApps()
        let items = await Task.detached { MenuBarScanner.scan(apps: apps) }.value
        let hiddenIDs = Set(statusBar.dividerFrameCG.map { MenuBarScanner.hidden(items, dividerFrame: $0).map(\.id) } ?? [])
        lines.append("")
        lines.append("Accessibility menu bar items (\(items.count)):")
        for item in items {
            let flag = hiddenIDs.contains(item.id) ? "HIDDEN " : "       "
            lines.append("  \(flag)\(item.appName) [\(item.pid)] \"\(item.label)\" frame=\(fmt(item.frame)) window=\(item.windowID.map(String.init) ?? "-") actions=\(AX.actions(item.element).joined(separator: ","))")
        }

        let windows = MenuBarScanner.statusWindows()
        lines.append("")
        lines.append("Status-level windows (\(windows.count)):")
        for w in windows.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            lines.append("  #\(w.id) \(w.ownerName) [\(w.ownerPID)] frame=\(fmt(w.frame)) onScreen=\(w.isOnScreen)")
        }

        let hidden = items.filter { hiddenIDs.contains($0.id) }
        let captured = await capturer.refresh(hidden)
        lines.append("")
        lines.append("Captured \(captured) of \(hidden.count) hidden items.")
        if let imageDirectory {
            try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            for (index, item) in hidden.enumerated() {
                guard let image = capturer.cache[item.id], let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { continue }
                let name = String(format: "%02d-%@.png", index, item.appName.replacingOccurrences(of: "/", with: "_"))
                try? png.write(to: imageDirectory.appendingPathComponent(name))
                lines.append("  saved \(name) template=\(image.isTemplate) size=\(image.size)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }
}
