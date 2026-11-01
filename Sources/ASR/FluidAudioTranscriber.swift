import FlowKit
import FluidAudio
import Foundation

/// Parakeet-family models running on the Neural Engine through FluidAudio.
public final class FluidAudioTranscriber: Transcriber, @unchecked Sendable {
    public enum Model: String, CaseIterable, Sendable {
        case v2  // English only
        case v3  // 25 European languages
        case ultra  // post-trained v3
        case bark3  // English, verbatim
        case bark3Clean = "bark3-clean"  // English, drops fillers, false starts and repeats

        var version: AsrModelVersion {
            switch self {
            case .v2: return .v2
            case .v3: return .v3
            case .ultra: return .ultra
            case .bark3: return .bark3
            case .bark3Clean: return .bark3Clean
            }
        }
    }

    public let name: String
    private let model: Model
    private let manager = AsrManager(config: .default)

    public init(model: Model) {
        self.model = model
        self.name = "parakeet-\(model.rawValue)"
    }

    public func prepare() async throws {
        let models = try await AsrModels.downloadAndLoad(version: model.version)
        try await manager.loadModels(models)
    }

    public func transcribe(samples: [Float]) async throws -> Transcript {
        // Decoder state carries over between calls, so each utterance starts fresh.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let start = ContinuousClock.now
        let result = try await manager.transcribe(samples, decoderState: &state)
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Transcript(text: result.text, seconds: seconds)
    }
}
