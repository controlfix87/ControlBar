import AppKit
import CoreGraphics

/// Hands the user's own, in-progress mouse drag over to a real menu bar item, so macOS runs its native
/// ⌘-drag on that item: the icon follows the pointer and its neighbours slide apart, exactly as if the
/// drag had started on the icon itself.
///
/// It works by pressing the item with one synthetic, window-addressed mouse-down, then re-addressing
/// the user's real drag and mouse-up events to the item's window as they pass through an event tap.
/// The window server routes by those window fields, so the item doesn't have to be under the pointer,
/// or even on-screen, when the hand-over starts. Because the real events are only re-addressed (never
/// re-posted), the pointer keeps moving exactly as the user moves it.
@MainActor
final class LiveDragTap {
    static let shared = LiveDragTap()
    /// Marks the events ControlBar posts itself, so the tap leaves them alone.
    static let eventTag: Int64 = 0x4342_4152 // "CBAR"

    private var tap: CFMachPort?
    private var windowID: Int64 = 0
    private var ownerPID: Int64 = 0
    private var onEnded: (() -> Void)?
    private var watchdog: Timer?
    private(set) var isActive = false

    /// Starts the hand-over with the pointer at `point` (global top-left coordinates). Returns false when
    /// the event tap can't be created (no Accessibility access); nothing has happened in that case.
    func begin(window: StatusWindow, at point: CGPoint, onEnded: @escaping () -> Void) -> Bool {
        guard !isActive, ensureTap() else { return false }
        windowID = Int64(window.id)
        ownerPID = Int64(window.ownerPID)
        self.onEnded = onEnded
        isActive = true
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        // Press the item. From here the window server treats the drag as the item's own.
        if let down = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .leftMouseDown,
                              mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            address(down)
            down.post(tap: .cgSessionEventTap)
        }

        // If the mouse-up is ever missed, don't keep redirecting the user's drags forever.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                if !CGEventSource.buttonState(.combinedSessionState, button: .left) { self.finish() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        return true
    }

    private func address(_ event: CGEvent) {
        event.flags.insert(.maskCommand)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: ownerPID)
        // Undocumented window-ID field the window server uses to route the event.
        if let field = CGEventField(rawValue: 0x33) { event.setIntegerValueField(field, value: windowID) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isActive, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard isActive, event.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return }
        switch type {
        case .leftMouseDragged:
            address(event)
        case .leftMouseUp:
            address(event)
            finish()
        case .leftMouseDown:
            finish() // a fresh press means the mouse-up was missed
        default:
            break
        }
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        watchdog?.invalidate()
        watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        let ended = onEnded
        onEnded = nil
        DispatchQueue.main.async { ended?() }
    }

    private func ensureTap() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: liveDragTapCallback, userInfo: nil)
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: false)
        tap = port
        return true
    }
}

/// Runs on the main run loop (the tap's source is added there).
private func liveDragTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated { LiveDragTap.shared.handle(type, event) }
    return Unmanaged.passUnretained(event)
}
