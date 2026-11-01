import Foundation

/// A vocabulary term an engine put in place of the word it first heard.
public struct VocabularyReplacement: Sendable, Equatable {
    /// What the engine decoded before vocabulary boosting ("over", "Superbase").
    public let original: String
    /// The vocabulary term that replaced it.
    public let term: String

    public init(original: String, term: String) {
        self.original = original
        self.term = term
    }
}

/// Result of one speech-to-text run.
public struct Transcript: Sendable, Equatable {
    public let text: String
    /// Wall-clock seconds spent transcribing (excludes model loading).
    public let seconds: Double
    /// Substitutions made by vocabulary boosting. Empty for engines without it.
    public let replacements: [VocabularyReplacement]
    /// Vocabulary terms the engine's keyword spotter heard in the audio, whether or not it changed the text.
    public let detectedTerms: [String]

    public init(text: String, seconds: Double, replacements: [VocabularyReplacement] = [], detectedTerms: [String] = []) {
        self.text = text
        self.seconds = seconds
        self.replacements = replacements
        self.detectedTerms = detectedTerms
    }
}

/// A speech-to-text engine. Every engine takes 16 kHz mono Float32 samples,
/// so engines can be swapped without touching audio capture.
public protocol Transcriber: Sendable {
    var name: String { get }
    /// Load models. Called once, so `transcribe` timings exclude loading.
    func prepare() async throws
    func transcribe(samples: [Float]) async throws -> Transcript
}
