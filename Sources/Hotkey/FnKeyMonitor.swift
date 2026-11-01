import AppKit
import CoreGraphics
import IOKit.hid

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

    public static var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted || CGPreflightListenEventAccess()
    }

    /// Shows the system prompt and adds Flow to the Input Monitoring list.
    /// `CGRequestListenEventAccess` alone didn't get Flow listed on macOS 26, but the HID request does.
    public static func requestPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
    }

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
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // These carry no real event, so don't touch it.
                MainActor.assumeIsolated { monitor.tapWasDisabled() }
                return nil
            }
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
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        reset()
    }

    /// Forgets any key that is currently held, e.g. after sleep or a screen lock, when the release may never arrive.
    public func reset() {
        gesture = HoldGesture(minimumHold: gesture.minimumHold)
    }

    /// macOS turns the tap off if the callback is slow. Turn it back on, and if the Fn release
    /// happened while it was off, finish the gesture so recording can't get stuck.
    private func tapWasDisabled() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        if gesture.isHolding, !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
            handle(.fnUp, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func receive(type: CGEventType, event: CGEvent) {
        // Not CGEvent.timestamp: on Apple Silicon its unit isn't reliably nanoseconds, and a wrong unit would make
        // every hold look too short. The system uptime is the same clock the rest of the gesture logic uses.
        let time = ProcessInfo.processInfo.systemUptime
        switch type {
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else { return }
            handle(event.flags.contains(.maskSecondaryFn) ? .fnDown : .fnUp, at: time)
        case .keyDown:
            // Flow presses ⌘V itself to paste. That must not look like the user pressing a key.
            guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
            let isEscape = event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode
            handle(isEscape ? .escape : .otherKeyDown, at: time)
        default:
            break
        }
    }

    private func handle(_ input: HotkeyInput, at time: TimeInterval) {
        if let result = gesture.handle(input, at: time) {
            onEvent?(result)
        }
    }
}
