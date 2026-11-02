import FlowKit
import Foundation
import Testing
@testable import Cleanup

/// A cleaner whose behaviour the test controls, and which counts calls.
private final class FakeCleaner: TextCleaner, @unchecked Sendable {
    let name = "fake"
    private let lock = NSLock()
    private var _calls = 0
    private let behaviour: @Sendable (String) async throws -> String

    init(_ behaviour: @escaping @Sendable (String) async throws -> String) {
        self.behaviour = behaviour
    }

    var calls: Int { lock.withLock { _calls } }
    func prepare() async throws {}
    func clean(_ raw: String) async throws -> String {
        lock.withLock { _calls += 1 }
        return try await behaviour(raw)
    }
}

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@Suite struct CleanupPipelineTests {
    private func pipeline(
        ai: TextCleaner?, timeout: Duration = .seconds(2), trusted: @escaping CleanupPipeline.Verdict = { _, _ in true }
    ) -> CleanupPipeline {
        CleanupPipeline(ai: ai, timeout: timeout, isTrusted: trusted)
    }

    @Test func offReturnsTheTranscriptUntouched() async {
        let ai = FakeCleaner { _ in "AI" }
        let result = await pipeline(ai: ai).clean("um so hello", mode: .off)
        #expect(result.text == "um so hello")
        #expect(!result.usedAI)
        #expect(ai.calls == 0)
    }

    @Test func rulesModeAppliesRulesAndNeverCallsTheAI() async {
        let ai = FakeCleaner { _ in "AI" }
        let result = await pipeline(ai: ai).clean("um so hello there", mode: .rules)
        #expect(result.text != "um so hello there")
        #expect(!result.text.lowercased().contains("um"))
        #expect(ai.calls == 0)
    }

    @Test func shortCleanTextSkipsTheAI() async {
        let ai = FakeCleaner { _ in "AI" }
        let result = await pipeline(ai: ai).clean("Please send the report today.", mode: .rulesAndAI)
        #expect(!result.usedAI)
        #expect(result.aiSkippedBecause == "not needed")
        #expect(ai.calls == 0)
    }

    @Test func aCorrectionCueSendsTextToTheAIAndUsesATrustedAnswer() async {
        let ai = FakeCleaner { _ in "Meet at four." }
        let result = await pipeline(ai: ai).clean("Let's meet at three, actually make that four.", mode: .rulesAndAI)
        #expect(result.usedAI)
        #expect(result.text == "Meet at four.")
        #expect(ai.calls == 1)
        #expect(result.aiSeconds != nil)
    }

    @Test func longTextGoesToTheAI() async {
        // Distinct words: the rules would collapse repeats as a stutter.
        let long = (1...40).map { "item\($0)" }.joined(separator: " ")
        let ai = FakeCleaner { _ in "cleaned" }
        let result = await pipeline(ai: ai).clean(long, mode: .rulesAndAI)
        #expect(ai.calls == 1)
        #expect(result.usedAI)
    }

    @Test func anUntrustedAnswerFallsBackToTheRulesOutput() async {
        let ai = FakeCleaner { _ in "Dear Bob, here is the email you asked for." }
        let result = await pipeline(ai: ai, trusted: { _, _ in false })
            .clean("Write an email to Bob, actually make it short.", mode: .rulesAndAI)
        #expect(!result.usedAI)
        #expect(result.aiSkippedBecause == "rejected by the safety check")
        #expect(!result.text.contains("Dear Bob"))
    }

    @Test func theVerdictSeesTheRulesOutputNotTheRawTranscript() async {
        let seen = OSLockedBox<String>()
        let ai = FakeCleaner { _ in "Okay." }
        _ = await pipeline(ai: ai, trusted: { input, _ in seen.set(input); return true })
            .clean("um okay actually", mode: .rulesAndAI)
        #expect(seen.value?.lowercased().contains("um") == false)
    }

    @Test func aThrowingAIFallsBackWithTheReason() async {
        let ai = FakeCleaner { _ in throw Boom() }
        let result = await pipeline(ai: ai).clean("Meet at three, actually four.", mode: .rulesAndAI)
        #expect(!result.usedAI)
        #expect(result.aiSkippedBecause?.contains("boom") == true)
        #expect(result.text.contains("Meet at three"))
    }

    @Test func aSlowAIIsAbandonedAfterTheTimeout() async {
        let ai = FakeCleaner { text in
            try await Task.sleep(for: .seconds(5))
            return text
        }
        let start = ContinuousClock.now
        let result = await pipeline(ai: ai, timeout: .milliseconds(150)).clean("Meet at three, actually four.", mode: .rulesAndAI)
        let elapsed = start.duration(to: .now)
        #expect(!result.usedAI)
        #expect(result.aiSkippedBecause?.contains("too long") == true)
        #expect(elapsed < .seconds(2))
    }

    @Test func aSlowAIIsCancelledAfterTheTimeout() async throws {
        let cancelled = OSLockedBox<Bool>()
        let ai = FakeCleaner { text in
            do {
                try await Task.sleep(for: .seconds(5))
                return text
            } catch {
                cancelled.set(true)
                throw error
            }
        }
        _ = await pipeline(ai: ai, timeout: .milliseconds(100)).clean("Meet at three, actually four.", mode: .rulesAndAI)
        try await Task.sleep(for: .milliseconds(300))
        #expect(cancelled.value == true)
    }

    @Test func longTextGetsAProportionallyLongerTimeBudget() {
        let pipeline = CleanupPipeline(ai: nil, timeout: .seconds(4))
        #expect(pipeline.budget(for: "short") == .seconds(4))
        #expect(pipeline.budget(for: String(repeating: "a", count: 1800)) == .seconds(4))
        #expect(pipeline.budget(for: String(repeating: "a", count: 1801)) == .seconds(8))
        #expect(pipeline.budget(for: String(repeating: "a", count: 5400)) == .seconds(12))
    }

    @Test func anEmptyAnswerIsNotUsed() async {
        let ai = FakeCleaner { _ in "   " }
        let result = await pipeline(ai: ai).clean("Meet at three, actually four.", mode: .rulesAndAI)
        #expect(!result.usedAI)
        #expect(result.aiSkippedBecause == "the AI returned nothing")
    }

    @Test func noAIAvailableStillGivesRulesOutput() async {
        let result = await pipeline(ai: nil).clean("Meet at three, actually four.", mode: .rulesAndAI)
        #expect(!result.usedAI)
        #expect(result.aiSkippedBecause == "AI cleanup is unavailable")
    }

    @Test func gateWantsLongTextAndCorrectionCuesOnly() {
        let gate = CleanupGate(longTextWords: 30)
        #expect(!gate.wantsAI(for: "Please send the report today."))
        #expect(gate.wantsAI(for: "Send it to Maria, no wait, send it to Marcus."))
        #expect(gate.wantsAI(for: "The deadline is Friday, I mean Monday."))
        #expect(gate.wantsAI(for: "On Tuesday, no, Wednesday."))
        #expect(gate.wantsAI(for: Array(repeating: "ordinary", count: 31).joined(separator: " ")))
    }
}

/// Collects a value from a `@Sendable` closure.
private final class OSLockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ newValue: Value) { lock.withLock { stored = newValue } }
}
