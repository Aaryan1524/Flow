import Foundation

/// What the keyboard did, reduced to the cases that matter for hold-to-talk.
public enum HotkeyInput: Sendable, Equatable {
    case fnDown
    case fnUp
    /// Any other key pressed (Fn+arrow, Fn+Delete, ...). Means Fn is acting as a modifier, not as the talk key.
    case otherKeyDown
    case escape
}

/// What the app should do about it.
public enum HotkeyEvent: Sendable, Equatable {
    /// Start capturing right away so the first word isn't clipped.
    case started
    /// Held long enough: stop capturing and transcribe.
    case finished
    /// Too short, or Fn was used with another key: throw the recording away.
    case cancelled
}

/// Turns raw key transitions into start / finish / cancel. Pure logic with no system calls, so it is fully testable.
///
/// Two ways to talk:
/// - **Hold:** press and hold Fn, release to finish.
/// - **Hands-free** (when `doubleTapWindow` is set): tap Fn twice quickly. Recording carries on after you let go;
///   tap Fn once more to finish, or press Esc to throw it away.
public struct HoldGesture: Sendable {
    /// Holds shorter than this are taps.
    public var minimumHold: TimeInterval
    /// How soon after one tap the next must come to count as a double-tap. `nil` turns hands-free mode off.
    public var doubleTapWindow: TimeInterval?

    private enum State {
        case idle
        /// `secondTap` is true for the press that follows a quick tap, which may turn into hands-free mode.
        case holding(since: TimeInterval, secondTap: Bool)
        /// Cancelled while still held; wait for the release before accepting a new press.
        case cancelledUntilRelease
        /// Recording with the key up, until the next tap.
        case handsFree
        /// The tap that ends hands-free recording is still down; wait for it to come up.
        case endingHandsFree
    }

    private var state = State.idle
    private var lastTapReleased: TimeInterval?

    public init(minimumHold: TimeInterval = 0.2, doubleTapWindow: TimeInterval? = nil) {
        self.minimumHold = minimumHold
        self.doubleTapWindow = doubleTapWindow
    }

    /// The key is physically down (so a missed release can be recovered by checking the keyboard).
    public var isHolding: Bool {
        switch state {
        case .holding, .endingHandsFree: return true
        default: return false
        }
    }

    /// Audio is being captured, with the key down or in hands-free mode.
    public var isRecording: Bool {
        switch state {
        case .holding, .handsFree: return true
        default: return false
        }
    }

    public mutating func handle(_ input: HotkeyInput, at time: TimeInterval) -> HotkeyEvent? {
        switch (state, input) {
        case (.idle, .fnDown):
            var secondTap = false
            if let window = doubleTapWindow, let last = lastTapReleased, time - last <= window { secondTap = true }
            lastTapReleased = nil
            state = .holding(since: time, secondTap: secondTap)
            return .started
        case (.holding(let since, let secondTap), .fnUp):
            // The tolerance absorbs floating point error: 10.2 - 10 is 0.19999999999999929.
            let held = time - since >= minimumHold - 1e-9
            if held {
                state = .idle
                return .finished
            }
            if secondTap {
                // Two quick taps: keep recording after the key comes up.
                state = .handsFree
                return nil
            }
            state = .idle
            lastTapReleased = time
            return .cancelled
        case (.holding, .otherKeyDown), (.holding, .escape):
            state = .cancelledUntilRelease
            lastTapReleased = nil
            return .cancelled
        case (.cancelledUntilRelease, .fnUp):
            state = .idle
            return nil
        case (.handsFree, .fnDown):
            state = .endingHandsFree
            return .finished
        case (.endingHandsFree, .fnUp):
            state = .idle
            return nil
        case (.handsFree, .escape):
            state = .idle
            return .cancelled
        default:
            // Repeated downs (key repeat), keys pressed while idle, or typing while talking hands-free.
            return nil
        }
    }
}
