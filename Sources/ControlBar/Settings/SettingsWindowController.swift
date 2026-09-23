import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel

    init(prefs: Preferences, sleep: SleepPreventer, model: SettingsModel) {
        self.model = model
        let hosting = NSHostingController(rootView: SettingsView(model: model, prefs: prefs, sleep: sleep))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ControlBar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
