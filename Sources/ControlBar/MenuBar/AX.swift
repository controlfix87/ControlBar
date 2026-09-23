import ApplicationServices
import CoreGraphics

/// Thin helpers over the Accessibility C API.
enum AX {
    static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(el, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        guard let s = copy(el, attribute) as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Frame in global screen coordinates with a top-left origin (same space as `CGWindowList`).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posValue = copy(el, kAXPositionAttribute), let sizeValue = copy(el, kAXSizeAttribute),
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    private static func copy(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
