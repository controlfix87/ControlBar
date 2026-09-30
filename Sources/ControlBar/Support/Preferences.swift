import Foundation
import Combine
import Carbon.HIToolbox

/// Menu shortcuts that can be re-assigned. They work while ControlBar's menu is open; only
/// "Show hidden icons" is global (a system-wide ⌘A would break Select All everywhere).
enum MenuShortcut: String, CaseIterable {
    case toggle, duration, display, arrange, settings, about, quit

    var title: String {
        switch self {
        case .toggle: "Turn keep awake on/off"
        case .duration: "Keep awake for…"
        case .display: "Keep screen on"
        case .arrange: "Arrange icons"
        case .settings: "Settings"
        case .about: "About"
        case .quit: "Quit"
        }
    }

    var icon: String {
        switch self {
        case .toggle: "power"
        case .duration: "timer"
        case .display: "display"
        case .arrange: "rectangle.3.group"
        case .settings: "gearshape"
        case .about: "info.circle"
        case .quit: "xmark.circle"
        }
    }

    var defaultCombo: KeyCombo {
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey)
        switch self {
        case .toggle: return KeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: cmd)
        case .duration: return KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: cmd)
        case .display: return KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: cmd | shift)
        case .arrange: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: cmd)
        case .settings: return KeyCombo(keyCode: UInt32(kVK_ANSI_Comma), carbonModifiers: cmd)
        case .about: return KeyCombo(keyCode: UInt32(kVK_ANSI_I), carbonModifiers: cmd)
        case .quit: return KeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: cmd)
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let autoHideDelay = "autoHideDelay"
        static let hideOnClickOutside = "hideOnClickOutside"
        static let pauseWhileHovering = "pauseWhileHovering"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let defaultDuration = "defaultDuration"
        static let activateOnLaunch = "activateOnLaunch"
        static let showKeepAwakeIcon = "showKeepAwakeIcon"
        static let showLogoIcon = "showLogoIcon"
        static let stripScale = "stripScale"
        static let stripColoredIcons = "stripColoredIcons"
        static let brandColors = "brandColors"
        static let preferInlineReveal = "preferInlineReveal"
        static let countdownShowSeconds = "countdownShowSeconds"
        static let didShowWelcome = "didShowWelcome"
    }

    private let defaults = UserDefaults.standard

    /// Seconds before the strip hides itself.
    @Published var autoHideDelay: Double { didSet { defaults.set(autoHideDelay, forKey: Key.autoHideDelay) } }
    @Published var hideOnClickOutside: Bool { didSet { defaults.set(hideOnClickOutside, forKey: Key.hideOnClickOutside) } }
    @Published var pauseWhileHovering: Bool { didSet { defaults.set(pauseWhileHovering, forKey: Key.pauseWhileHovering) } }

    /// Overrides of the default menu shortcuts, by `MenuShortcut.rawValue`.
    @Published private(set) var shortcutOverrides: [String: KeyCombo] = [:]

    func shortcut(_ action: MenuShortcut) -> KeyCombo { shortcutOverrides[action.rawValue] ?? action.defaultCombo }

    func setShortcut(_ action: MenuShortcut, _ combo: KeyCombo) {
        shortcutOverrides[action.rawValue] = combo
        defaults.set(["code": Int(combo.keyCode), "mods": Int(combo.carbonModifiers)], forKey: "shortcut." + action.rawValue)
    }

    func resetShortcut(_ action: MenuShortcut) {
        shortcutOverrides[action.rawValue] = nil
        defaults.removeObject(forKey: "shortcut." + action.rawValue)
    }

    @Published var hotKeyEnabled: Bool { didSet { defaults.set(hotKeyEnabled, forKey: Key.hotKeyEnabled) } }
    @Published var hotKey: KeyCombo {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(hotKey.carbonModifiers), forKey: Key.hotKeyModifiers)
        }
    }

    /// Also prevent the display from sleeping (not just the system).
    @Published var keepDisplayAwake: Bool { didSet { defaults.set(keepDisplayAwake, forKey: Key.keepDisplayAwake) } }
    /// Duration used by a plain click on the keep-awake icon. 0 means indefinitely.
    @Published var defaultDuration: Double { didSet { defaults.set(defaultDuration, forKey: Key.defaultDuration) } }
    @Published var activateOnLaunch: Bool { didSet { defaults.set(activateOnLaunch, forKey: Key.activateOnLaunch) } }
    @Published var showKeepAwakeIcon: Bool { didSet { defaults.set(showKeepAwakeIcon, forKey: Key.showKeepAwakeIcon) } }
    /// Size of the popup strip's icons, as a multiple of their natural size.
    @Published var stripScale: Double { didSet { defaults.set(stripScale, forKey: Key.stripScale) } }
    /// Strip icons keep the colours they have in the menu bar; off = single-colour glyphs follow the strip's label colour.
    @Published var stripColoredIcons: Bool { didSet { defaults.set(stripColoredIcons, forKey: Key.stripColoredIcons) } }
    /// Menu bar icons use ControlBar's brand colours; off = plain macOS monochrome.
    @Published var brandColors: Bool { didSet { defaults.set(brandColors, forKey: Key.brandColors) } }
    /// Shows ControlBar's own logo glyph to the right of the chevron.
    @Published var showLogoIcon: Bool { didSet { defaults.set(showLogoIcon, forKey: Key.showLogoIcon) } }
    /// When there's enough free menu bar space, reveal hidden icons in place instead of the strip.
    @Published var preferInlineReveal: Bool { didSet { defaults.set(preferInlineReveal, forKey: Key.preferInlineReveal) } }
    /// The menu bar countdown counts down to the second (e.g. "45", "01:02:03") instead of only
    /// to the minute (e.g. "1", "1:02").
    @Published var countdownShowSeconds: Bool { didSet { defaults.set(countdownShowSeconds, forKey: Key.countdownShowSeconds) } }

    var didShowWelcome: Bool {
        get { defaults.bool(forKey: Key.didShowWelcome) }
        set { defaults.set(newValue, forKey: Key.didShowWelcome) }
    }

    private init() {
        defaults.register(defaults: [
            Key.autoHideDelay: 7.0,
            Key.hideOnClickOutside: true,
            Key.pauseWhileHovering: true,
            Key.hotKeyEnabled: true,
            Key.hotKeyCode: Int(KeyCombo.default.keyCode),
            Key.hotKeyModifiers: Int(KeyCombo.default.carbonModifiers),
            Key.keepDisplayAwake: true,
            Key.defaultDuration: 0.0,
            Key.activateOnLaunch: false,
            Key.showKeepAwakeIcon: true,
            Key.showLogoIcon: true,
            Key.stripScale: 1.0,
            Key.stripColoredIcons: true,
            Key.brandColors: true,
            Key.preferInlineReveal: false,
            Key.countdownShowSeconds: true,
        ])
        autoHideDelay = defaults.double(forKey: Key.autoHideDelay)
        hideOnClickOutside = defaults.bool(forKey: Key.hideOnClickOutside)
        pauseWhileHovering = defaults.bool(forKey: Key.pauseWhileHovering)
        hotKeyEnabled = defaults.bool(forKey: Key.hotKeyEnabled)
        hotKey = KeyCombo(keyCode: UInt32(defaults.integer(forKey: Key.hotKeyCode)),
                          carbonModifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers)))
        keepDisplayAwake = defaults.bool(forKey: Key.keepDisplayAwake)
        defaultDuration = defaults.double(forKey: Key.defaultDuration)
        activateOnLaunch = defaults.bool(forKey: Key.activateOnLaunch)
        showKeepAwakeIcon = defaults.bool(forKey: Key.showKeepAwakeIcon)
        showLogoIcon = defaults.bool(forKey: Key.showLogoIcon)
        stripScale = defaults.double(forKey: Key.stripScale)
        stripColoredIcons = defaults.bool(forKey: Key.stripColoredIcons)
        brandColors = defaults.bool(forKey: Key.brandColors)
        preferInlineReveal = defaults.bool(forKey: Key.preferInlineReveal)
        countdownShowSeconds = defaults.bool(forKey: Key.countdownShowSeconds)
        for action in MenuShortcut.allCases {
            if let d = defaults.dictionary(forKey: "shortcut." + action.rawValue), let code = d["code"] as? Int, let mods = d["mods"] as? Int {
                shortcutOverrides[action.rawValue] = KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(mods))
            }
        }
    }
}
