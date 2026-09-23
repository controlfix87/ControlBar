import SwiftUI
import ServiceManagement

enum SettingsTab: String, Hashable {
    case general, keepAwake, hiddenIcons, shortcuts, permissions, about
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
    var arrange: () -> Void = {}
    var diagnostics: () async -> String = { "" }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var sleep: SleepPreventer

    private let tabs: [(SettingsTab, String, String)] = [
        (.general, "General", "gearshape"),
        (.keepAwake, "Keep Awake", "cup.and.saucer"),
        (.hiddenIcons, "Hidden Icons", "menubar.rectangle"),
        (.shortcuts, "Shortcuts", "command"),
        (.permissions, "Permissions", "lock.shield"),
        (.about, "About", "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.0) { tab, title, icon in
                    let selected = model.tab == tab
                    Button { model.tab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                            Text(title).font(.system(size: 10.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? Brand.mint : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Brand.teal.opacity(0.22) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Brand.navy.opacity(0.55))
            Divider()

            Group {
                switch model.tab {
                case .general: GeneralTab(prefs: prefs)
                case .keepAwake: KeepAwakeTab(prefs: prefs, sleep: sleep)
                case .hiddenIcons: HiddenIconsTab(prefs: prefs, arrange: model.arrange)
                case .shortcuts: ShortcutsTab(prefs: prefs)
                case .permissions: PermissionsTab()
                case .about: AboutTab(diagnostics: model.diagnostics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 520, height: 500)
        .tint(Brand.teal)
        .toggleStyle(PillToggleStyle())
    }
}

// MARK: - Shared pieces

/// A compact pill switch with "ON"/"OFF" written in the empty part of the track.
private struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack {
                Capsule().fill(configuration.isOn ? Brand.teal : Color.secondary.opacity(0.35))
                Text(configuration.isOn ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: configuration.isOn ? .leading : .trailing)
                    .padding(.horizontal, 8)
                Circle().fill(.white).shadow(radius: 0.5).padding(2)
                    .frame(maxWidth: .infinity, alignment: configuration.isOn ? .trailing : .leading)
            }
            .frame(width: 52, height: 24)
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } }
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Icon in a fixed-width column so every row's text lines up.
private struct BrandLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(Brand.teal).frame(width: 20)
            configuration.title
        }
    }
}

private struct TabIntro: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
    }
}

private func row(_ title: String, _ icon: String) -> some View {
    Label(title, systemImage: icon).labelStyle(BrandLabelStyle())
}

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            TabIntro("Basic options for ControlBar.")
            Form {
                Section {
                    Toggle(isOn: $launchAtLogin) { row("Launch at login", "power") }
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                    Toggle(isOn: $prefs.showKeepAwakeIcon) { row("Keep-awake icon", "moon.zzz") }
                    Toggle(isOn: $prefs.showLogoIcon) { row("ControlBar icon", "dial.medium") }
                    Toggle(isOn: $prefs.brandColors) { row("Brand colors in menu bar", "paintpalette") }
                    HStack {
                        row("Show hidden icons", "keyboard")
                        Spacer()
                        HotKeyRecorder(combo: $prefs.hotKey).disabled(!prefs.hotKeyEnabled)
                        Toggle("", isOn: $prefs.hotKeyEnabled).labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct KeepAwakeTab: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var sleep: SleepPreventer
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var isOn: Binding<Bool> {
        Binding(get: { sleep.isActive }, set: { on in
            if on {
                sleep.activate(for: prefs.defaultDuration > 0 ? prefs.defaultDuration : nil,
                               keepDisplayAwake: prefs.keepDisplayAwake)
            } else {
                sleep.deactivate()
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            TabIntro("Stops your Mac from sleeping. Closing the lid still sleeps a laptop.")
            Form {
                Section {
                    Toggle(isOn: isOn) {
                        VStack(alignment: .leading, spacing: 1) {
                            row("Keep awake", "cup.and.saucer")
                            Text(sleep.statusDescription).font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                        }
                        .id(now)
                    }
                }
                Section {
                    Picker(selection: $prefs.defaultDuration) {
                        ForEach(KeepAwakeDuration.presets, id: \.seconds) { preset in
                            Text(preset.title).tag(preset.seconds)
                        }
                    } label: { row("Default time", "timer") }
                    Toggle(isOn: $prefs.keepDisplayAwake) { row("Keep screen on", "display") }
                        .onChange(of: prefs.keepDisplayAwake) { _, value in sleep.setKeepDisplayAwake(value) }
                    Toggle(isOn: $prefs.activateOnLaunch) { row("Turn on at launch", "bolt") }
                }
            }
            .formStyle(.grouped)
        }
        .onReceive(tick) { now = $0 }
    }
}

private struct HiddenIconsTab: View {
    @ObservedObject var prefs: Preferences
    let arrange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabIntro("⌘-drag icons left of the ┃ to hide them. Click the knob to show them.")
            Form {
                Section {
                    LabeledContent { HStack {
                        Slider(value: $prefs.autoHideDelay, in: 2...30, step: 1)
                        Text("\(Int(prefs.autoHideDelay)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                    } } label: { row("Hide after", "timer") }
                    LabeledContent { HStack {
                        Slider(value: $prefs.stripScale, in: 0.75...2.0, step: 0.05)
                        Text("\(Int((prefs.stripScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    } } label: { row("Icon size", "arrow.up.left.and.arrow.down.right") }
                    Toggle(isOn: $prefs.hideOnClickOutside) { row("Hide on outside click", "cursorarrow.click") }
                    Toggle(isOn: $prefs.pauseWhileHovering) { row("Keep menu visible while hovering", "hand.point.up.left") }
                    Toggle(isOn: $prefs.preferInlineReveal) { row("Use menu bar if it fits", "menubar.rectangle") }
                }
                Section {
                    Button(action: arrange) { row("Arrange icons…", "rectangle.3.group") }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 0) {
            TabIntro("Menu shortcuts work while the ControlBar menu is open.")
            Form {
                Section {
                    ForEach(MenuShortcut.allCases, id: \.self) { action in
                        HStack {
                            row(action.title, action.icon)
                            Spacer()
                            HotKeyRecorder(combo: Binding(get: { prefs.shortcut(action) }, set: { prefs.setShortcut(action, $0) }))
                            Button { prefs.resetShortcut(action) } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.borderless)
                                .help("Reset to default")
                                .disabled(prefs.shortcut(action) == action.defaultCombo)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct PermissionsTab: View {
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    @State private var relaunching = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            TabIntro("ControlBar only reads the small menu bar icons it shows.")
            Form {
                Section {
                    PermissionRow(title: "Accessibility", icon: "hand.raised", granted: accessibility,
                                  detail: "Finds and opens hidden icons.",
                                  action: Permissions.requestAccessibility, settingsAnchor: "Privacy_Accessibility")
                    PermissionRow(title: "Screen Recording", icon: "record.circle", granted: screenRecording || relaunching,
                                  detail: "Shows real icon pictures in the strip.",
                                  action: Permissions.requestScreenRecording, settingsAnchor: "Privacy_ScreenCapture")
                } footer: {
                    HStack {
                        Spacer()
                        Button("Relaunch ControlBar", action: Permissions.relaunch).controlSize(.small)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onReceive(tick) { _ in
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
            if Permissions.screenRecordingGrantedPendingRelaunch, !relaunching {
                // Granted, but macOS only applies it to a fresh process — restart so it just works.
                relaunching = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Permissions.relaunch() }
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let icon: String
    let granted: Bool
    let detail: String
    let action: () -> Void
    let settingsAnchor: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.teal).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.headline)
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(granted ? .green : .orange)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Grant…", action: action)
                    Button("Open System Settings") { Permissions.openPrivacyPane(settingsAnchor) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AboutTab: View {
    let diagnostics: () async -> String
    @State private var report = ""
    @State private var copied = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Brand banner — navy→ink ground, the mark, and a version pill, the way the other
            // ControlFix-design-system apps (e.g. Translarr) present their About screen.
            ZStack {
                LinearGradient(colors: [Brand.navy, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 12) {
                    Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("ControlBar").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                            Text("v\(version)")
                                .font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Brand.teal.opacity(0.25))
                                .foregroundStyle(Brand.mint)
                                .clipShape(Capsule())
                        }
                        Text("Keep your Mac awake. Hide menu bar icons.")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .frame(height: 92)

            VStack(spacing: 10) {
                Text("Open source · MIT License")
                    .font(.callout).foregroundStyle(.secondary)
                Divider().padding(.vertical, 2)
                HStack {
                    Button(copied ? "Copied!" : "Copy Diagnostics") {
                        Task {
                            report = await diagnostics()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                            copied = true
                        }
                    }
                    Text("For bug reports.").font(.caption).foregroundStyle(.secondary)
                }
                if !report.isEmpty {
                    ScrollView {
                        Text(report).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }
}

// MARK: - Shortcut recorder

private struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type a shortcut…" : combo.displayString) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels
                stop()
            } else if let newCombo = KeyCombo(event: event) {
                combo = newCombo
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
