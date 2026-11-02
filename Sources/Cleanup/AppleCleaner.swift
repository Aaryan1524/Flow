import FlowKit
import Foundation
import FoundationModels

/// Cleanup with Apple's on-device Foundation Models.
///
/// Uses the permissive content-transformation guardrails, since dictation is a text transformation
/// and the default guardrails reject some ordinary speech. Replies are plain text, and every call
/// gets a fresh session so one dictation never leaks into the next. Failures surface as
/// `CleanupError` so callers can fall back to the rules output.
public final class AppleCleaner: TextCleaner, Sendable {
    public let name = "apple"
    private let model: SystemLanguageModel

    public init() {
        model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    public func prepare() async throws {
        switch model.availability {
        case .available:
            makeSession().prewarm()
        case .unavailable(let reason):
            throw CleanupError.unavailable("Apple Intelligence model is not available (\(Self.describe(reason)))")
        }
    }

    public func clean(_ raw: String) async throws -> String {
        let chunks = TextChunker.split(raw, maxCharacters: CleanupPrompt.maxChunkCharacters)
        var cleaned: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()  // stop early when the pipeline has given up
            cleaned.append(try await cleanChunk(chunk.text))
        }
        return CleanupPrompt.join(cleaned, separators: chunks.map(\.separator))
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: CleanupPrompt.instructions)
    }

    private func cleanChunk(_ text: String) async throws -> String {
        let options = GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens: CleanupPrompt.maxOutputTokens(forInput: text))
        do {
            let response = try await makeSession().respond(to: CleanupPrompt.userMessage(for: text), options: options)
            let output = CleanupPrompt.extractOutput(from: response.content, original: text)
            guard !output.isEmpty else { throw CleanupError.emptyResponse }
            return output
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> CleanupError {
        switch error {
        case .exceededContextWindowSize:
            return .contextTooLong("exceeded the 4,096-token context window")
        case .guardrailViolation:
            return .blocked("guardrail violation")
        case .refusal:
            return .blocked("the model refused")
        case .assetsUnavailable:
            return .unavailable("model assets are not downloaded")
        case .rateLimited, .concurrentRequests:
            return .busy(error.errorDescription ?? "rate limited")
        default:
            return .failed(error.errorDescription ?? "\(error)")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
        case .modelNotReady: return "model not ready yet"
        @unknown default: return "unknown reason"
        }
    }
}
