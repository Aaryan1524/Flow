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
public struct HoldGesture: Sendable {
    /// Holds shorter than this are accidental taps.
    public var minimumHold: TimeInterval

    private enum State {
        case idle
        case holding(since: TimeInterval)
        /// Cancelled while still held; wait for the release before accepting a new press.
        case cancelledUntilRelease
    }

    private var state = State.idle

    public init(minimumHold: TimeInterval = 0.2) {
        self.minimumHold = minimumHold
    }

    public var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    public mutating func handle(_ input: HotkeyInput, at time: TimeInterval) -> HotkeyEvent? {
        switch (state, input) {
        case (.idle, .fnDown):
            state = .holding(since: time)
            return .started
        case (.holding(let since), .fnUp):
            state = .idle
            // The tolerance absorbs floating point error: 10.2 - 10 is 0.19999999999999929.
            return time - since >= minimumHold - 1e-9 ? .finished : .cancelled
        case (.holding, .otherKeyDown), (.holding, .escape):
            state = .cancelledUntilRelease
            return .cancelled
        case (.cancelledUntilRelease, .fnUp):
            state = .idle
            return nil
        default:
            // Repeated downs (key repeat), or keys pressed while idle.
            return nil
        }
    }
}
