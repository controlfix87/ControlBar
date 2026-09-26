import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let sleep = SleepPreventer()
    private let capturer = ItemImageCapturer()
    private var statusBar: StatusBarController!
    private var activator: ItemActivator!
    private var strip: StripController!
    private var settings: SettingsWindowController?
    private let settingsModel = SettingsModel()
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(prefs: prefs, sleep: sleep)
        activator = ItemActivator(statusBar: statusBar)
        strip = StripController(prefs: prefs, statusBar: statusBar, capturer: capturer, activator: activator)

        statusBar.onShowStrip = { [weak self] in self?.strip.toggle() }
        statusBar.onOpenSettings = { [weak self] in self?.openSettings() }
        statusBar.onOpenAbout = { [weak self] in self?.openSettings(tab: .about) }
        statusBar.onOpenPermissions = { [weak self] in self?.openSettings(tab: .permissions) }
        strip.onOpenPermissions = { [weak self] in self?.openSettings(tab: .permissions) }
        statusBar.onArrangingChanged = { [weak self] arranging in
            guard let self else { return }
            if arranging {
                self.strip.showHint("Hold ⌘ and drag icons to the left of the ┃ divider to hide them. Click ✓ when you're done.")
            } else {
                self.strip.hide()
            }
        }
        statusBar.onEndArrangingRequested = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.captureHiddenItems()
                self.statusBar.setArranging(false)
            }
        }
        statusBar.onInvalidOrder = { [weak self] in
            self?.strip.showHint("ControlBar can't hide icons while the ┃ divider is to the right of its ⌄ icon. Hold ⌘ and drag the divider to the left.")
        }
        activator.onItemsRevealed = { [weak self] in
            Task { @MainActor in await self?.captureHiddenItems() }
        }

        settingsModel.arrange = { [weak self] in self?.statusBar.setArranging(true) }
        settingsModel.diagnostics = { [weak self] in
            guard let self else { return "" }
            return await Diagnostics.report(statusBar: self.statusBar, capturer: self.capturer)
        }

        Publishers.CombineLatest(prefs.$hotKeyEnabled, prefs.$hotKey)
            .sink { [weak self] enabled, combo in self?.registerHotKey(enabled: enabled, combo: combo) }
            .store(in: &cancellables)

        if prefs.activateOnLaunch {
            statusBar.activateKeepAwake(for: prefs.defaultDuration)
        }

        if let dir = diagnoseDirectory() {
            runDiagnosticsAndQuit(to: dir)
            return
        }

        // Let the menu bar lay out our items, grab pictures of the soon-to-be-hidden icons
        // while they're still visible, then hide them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.captureHiddenItems()
                self.statusBar.hideItems()
            }
        }

        if !prefs.didShowWelcome || !Permissions.accessibility {
            prefs.didShowWelcome = true
            openSettings(tab: .permissions)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleep.deactivate()
    }

    // MARK: - Helpers

    private func openSettings(tab: SettingsTab? = nil) {
        if settings == nil {
            settings = SettingsWindowController(prefs: prefs, sleep: sleep, model: settingsModel)
        }
        settings?.show(tab: tab)
    }

    private func registerHotKey(enabled: Bool, combo: KeyCombo) {
        hotKey = nil
        guard enabled else { return }
        hotKey = HotKey(combo: combo) { [weak self] in
            MainActor.assumeIsolated { self?.strip.toggle() }
        }
        if hotKey == nil {
            NSLog("ControlBar: could not register shortcut \(combo.displayString); it may be taken by another app")
        }
    }

    /// Refreshes pictures of every item left of the divider.
    private func captureHiddenItems() async {
        guard Permissions.accessibility, Permissions.screenRecording, let divider = statusBar.dividerFrameCG else { return }
        let apps = MenuBarScanner.runningApps()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let items = await Task.detached { MenuBarScanner.scan(apps: apps, excludingPID: ownPID) }.value
        await capturer.refresh(MenuBarScanner.hidden(items, dividerFrame: divider))
    }

    // MARK: - Diagnostics mode (`open ControlBar.app --args --diagnose <dir>`)

    private func diagnoseDirectory() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--diagnose"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    private func runDiagnosticsAndQuit(to dir: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            let revealed = await Diagnostics.report(statusBar: statusBar, capturer: capturer,
                                                    imageDirectory: dir.appendingPathComponent("revealed"))
            statusBar.hideItems()
            try? await Task.sleep(for: .milliseconds(800))
            let hidden = await Diagnostics.report(statusBar: statusBar, capturer: ItemImageCapturer(),
                                                  imageDirectory: dir.appendingPathComponent("hidden"))
            let text = "===== REVEALED =====\n\(revealed)\n\n===== HIDDEN =====\n\(hidden)\n"
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
