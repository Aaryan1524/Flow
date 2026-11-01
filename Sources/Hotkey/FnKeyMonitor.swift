import AppKit
import CoreGraphics

/// Watches the Fn / Globe key with a listen-only event tap. Needs the Input Monitoring permission.
///
/// Fn is detected from `flagsChanged` events with keycode 63. The secondary-Fn flag on ordinary key events
/// is not used: macOS sets it on arrow and function keys too.
@MainActor
public final class FnKeyMonitor {
    private static let fnKeyCode: Int64 = 63
    private static let escapeKeyCode: Int64 = 53

    public var onEvent: ((HotkeyEvent) -> Void)?

    private var gesture: HoldGesture
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(minimumHold: TimeInterval = 0.2) {
        gesture = HoldGesture(minimumHold: minimumHold)
    }

    public static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt if the permission hasn't been decided yet.
    public static func requestPermission() { _ = CGRequestListenEventAccess() }

    public var isRunning: Bool { tap != nil }

    /// Returns false when the tap can't be created, which means Input Monitoring isn't granted yet.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's run loop source is on the main run loop, so this runs on the main thread.
            MainActor.assumeIsolated { monitor.receive(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
        gesture = HoldGesture(minimumHold: gesture.minimumHold)
    }

    private func receive(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns the tap off if the callback is slow. Turn it back on, and if the Fn release
            // happened while it was off, finish the gesture so recording can't get stuck.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if gesture.isHolding, !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
                handle(.fnUp)
            }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else { return }
            handle(event.flags.contains(.maskSecondaryFn) ? .fnDown : .fnUp)
        case .keyDown:
            let isEscape = event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode
            handle(isEscape ? .escape : .otherKeyDown)
        default:
            break
        }
    }

    private func handle(_ input: HotkeyInput) {
        if let result = gesture.handle(input, at: ProcessInfo.processInfo.systemUptime) {
            onEvent?(result)
        }
    }
}
