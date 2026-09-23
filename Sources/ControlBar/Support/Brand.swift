import SwiftUI

/// ControlBar's brand palette (ControlFix design system). Source of truth for the marks
/// themselves is ~/develop/assets/Icons/ControlBar — keep colours in sync with that README.
enum Brand {
    static let lime = Color(red: 0xA9 / 255, green: 0xF0 / 255, blue: 0x00 / 255)
    static let limeDeep = Color(red: 0x7C / 255, green: 0xC8 / 255, blue: 0x00 / 255)
    static let mint = Color(red: 0x31 / 255, green: 0xDC / 255, blue: 0xC0 / 255)
    static let teal = Color(red: 0x17 / 255, green: 0xB3 / 255, blue: 0xA4 / 255)
    static let tealDeep = Color(red: 0x0E / 255, green: 0x8E / 255, blue: 0x93 / 255)
    static let navy = Color(red: 0x10 / 255, green: 0x1D / 255, blue: 0x33 / 255)
}
