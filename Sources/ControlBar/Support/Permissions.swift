import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The two privacy permissions the hidden-icons strip relies on.
enum Permissions {
    /// Needed to find menu bar items, read their positions and press them.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Needed to capture pictures of hidden menu bar items. Without it the strip falls back to app icons.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// True once the user has granted Screen Recording in System Settings, even though this running
    /// process can't use it yet. macOS only reveals other apps' window titles to a process that has
    /// been granted access, so a titled foreign window is a live signal that doesn't need a relaunch.
    static var screenRecordingGrantedPendingRelaunch: Bool {
        guard !screenRecording,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return info.contains { w in
            (w[kCGWindowOwnerPID as String] as? pid_t) != me
                && (w[kCGWindowLayer as String] as? Int) == 0
                && !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// On recent macOS an app is only listed under Privacy → Screen & System Audio Recording once it has
    /// actually tried to capture with ScreenCaptureKit, which is what the icon capturer uses. So besides the
    /// classic request, make a real (harmless) ScreenCaptureKit call to register the app in that list.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording grants only take effect after a relaunch.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
