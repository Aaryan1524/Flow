import Foundation

/// Result of one speech-to-text run.
public struct Transcript: Sendable, Equatable {
    public let text: String
    /// Wall-clock seconds spent transcribing (excludes model loading).
    public let seconds: Double

    public init(text: String, seconds: Double) {
        self.text = text
        self.seconds = seconds
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
