import FlowKit
import Foundation
import os

/// How much cleanup to apply to a transcript.
public enum CleanupMode: String, Sendable, CaseIterable {
    /// Leave the speech-to-text output exactly as it came.
    case off
    /// Deterministic rules only: fillers, stutters, spoken punctuation, capitalisation. Instant.
    case rules
    /// Rules, then the AI model for text that needs it (self-corrections, long dictation), checked by the guard.
    case rulesAndAI
}

/// Decides whether text is worth the AI step, which costs roughly half a second.
public struct CleanupGate: Sendable {
    /// Long dictation benefits from AI punctuation and paragraphing.
    public var longTextWords: Int

    public init(longTextWords: Int = 30) {
        self.longTextWords = longTextWords
    }

    /// Phrases that usually mean the speaker is taking something back. Broad on purpose: a false alarm only
    /// costs a little time, while a miss leaves "Tuesday, no, Wednesday" in the text.
    static let cues = [
        "scratch that", "strike that", "never mind", "nevermind", "make that", "i mean", "or rather", "no wait", "wait no",
        "actually", "sorry", "oops", "correction", ", no,", ", no ", "rather than",
    ]

    public func wantsAI(for text: String) -> Bool {
        if text.split(whereSeparator: \.isWhitespace).count >= longTextWords { return true }
        let lowered = text.lowercased()
        return Self.cues.contains { lowered.contains($0) }
    }
}

/// The outcome of cleaning one transcript, with enough detail to log and to explain a fallback.
public struct CleanupResult: Sendable, Equatable {
    /// The text to insert.
    public let text: String
    /// What the speech engine produced, untouched.
    public let raw: String
    /// Whether the AI's output is what `text` contains.
    public let usedAI: Bool
    /// Why the AI step didn't contribute, when it didn't ("not needed", "rejected by safety check", ...).
    public let aiSkippedBecause: String?
    public let aiSeconds: Double?
}

public enum CleanupPipelineError: Error, LocalizedError {
    case timedOut

    public var errorDescription: String? { "the AI cleanup took too long" }
}

/// raw transcript -> rules -> (maybe) AI -> safety check -> text.
///
/// Whatever the AI does, the worst outcome is the rules output: a slow, failing or untrustworthy AI result is
/// dropped, never inserted.
public final class CleanupPipeline: Sendable {
    /// Returns true when the AI output is trustworthy relative to its input.
    public typealias Verdict = @Sendable (_ input: String, _ output: String) -> Bool

    private let rules: TextCleaner
    private let ai: TextCleaner?
    private let gate: CleanupGate
    private let timeout: Duration
    private let isTrusted: Verdict

    public init(
        rules: TextCleaner = RulesCleaner(), ai: TextCleaner?, gate: CleanupGate = CleanupGate(),
        timeout: Duration = .seconds(4),
        isTrusted: @escaping Verdict = { CleanupGuard.standard.evaluate(raw: $0, cleaned: $1).isTrustworthy }
    ) {
        self.rules = rules
        self.ai = ai
        self.gate = gate
        self.timeout = timeout
        self.isTrusted = isTrusted
    }

    public func clean(_ raw: String, mode: CleanupMode) async -> CleanupResult {
        guard mode != .off else {
            return CleanupResult(text: raw, raw: raw, usedAI: false, aiSkippedBecause: "cleanup is off", aiSeconds: nil)
        }
        // Rules never throw in practice; if one ever did, the untouched transcript is still the right fallback.
        let ruled = (try? await rules.clean(raw)) ?? raw
        func rulesOnly(_ reason: String, seconds: Double? = nil) -> CleanupResult {
            CleanupResult(text: ruled, raw: raw, usedAI: false, aiSkippedBecause: reason, aiSeconds: seconds)
        }

        guard mode == .rulesAndAI else { return rulesOnly("AI cleanup is off") }
        guard let ai else { return rulesOnly("AI cleanup is unavailable") }
        guard gate.wantsAI(for: ruled) else { return rulesOnly("not needed") }

        let start = ContinuousClock.now
        do {
            let output = try await race(ai, ruled)
            let seconds = Self.seconds(start.duration(to: .now))
            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return rulesOnly("the AI returned nothing", seconds: seconds) }
            guard isTrusted(ruled, cleaned) else { return rulesOnly("rejected by the safety check", seconds: seconds) }
            return CleanupResult(text: cleaned, raw: raw, usedAI: true, aiSkippedBecause: nil, aiSeconds: seconds)
        } catch {
            return rulesOnly("the AI failed: \(error.localizedDescription)", seconds: Self.seconds(start.duration(to: .now)))
        }
    }

    /// Runs the AI but gives up after `timeout`. The AI call is not cancelled (it may not honour cancellation);
    /// its late result is simply ignored.
    private func race(_ ai: TextCleaner, _ text: String) async throws -> String {
        let finished = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = self.timeout
            Task {
                do {
                    let output = try await ai.clean(text)
                    if Self.claim(finished) { continuation.resume(returning: output) }
                } catch {
                    if Self.claim(finished) { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if Self.claim(finished) { continuation.resume(throwing: CleanupPipelineError.timedOut) }
            }
        }
    }

    /// True for exactly one caller.
    private static func claim(_ flag: OSAllocatedUnfairLock<Bool>) -> Bool {
        flag.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
