import Foundation

/// Why a cleaner could not produce text. Callers catch this and fall back to a simpler cleaner
/// (usually the deterministic rules output) instead of failing the dictation.
public enum CleanupError: Error, Sendable, Equatable, LocalizedError {
    /// The engine cannot run at all: model missing, server down, Apple Intelligence off.
    case unavailable(String)
    /// The model's safety layer refused the text.
    case blocked(String)
    /// The text does not fit in the model's context window.
    case contextTooLong(String)
    /// The engine is busy with another request.
    case busy(String)
    /// The engine answered with nothing usable.
    case emptyResponse
    /// Anything else: network errors, malformed replies.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "cleaner unavailable: \(detail)"
        case .blocked(let detail): return "cleaner blocked the text: \(detail)"
        case .contextTooLong(let detail): return "text too long for the model: \(detail)"
        case .busy(let detail): return "cleaner busy: \(detail)"
        case .emptyResponse: return "cleaner returned an empty response"
        case .failed(let detail): return "cleaner failed: \(detail)"
        }
    }
}

/// Turns a raw transcript into clean, faithful text: fillers, stutters and self-corrections
/// removed, punctuation and capitalization fixed, the speaker's words otherwise untouched.
public protocol TextCleaner: Sendable {
    var name: String { get }
    /// Load models or check the engine is reachable. Called once, so `clean` timings exclude loading.
    func prepare() async throws
    func clean(_ raw: String) async throws -> String
}
