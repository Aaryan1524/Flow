import FlowKit
import FluidAudio
import Foundation
import Synchronization

/// Parakeet-family models running on the Neural Engine through FluidAudio.
///
/// With a vocabulary, the transcript is rescored against a second, small CTC model (parakeet-ctc-110m)
/// that listens to the same audio for the listed terms. FluidAudio 0.18.0 only wires this into its
/// sliding-window and unified managers, not the `AsrManager` used here, so this applies the public
/// `VocabularyBoostingSession` to the result the same way FluidAudio's own batch CLI does.
public final class FluidAudioTranscriber: Transcriber {
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
    private let vocabulary: [String]
    private let manager = AsrManager(config: .default)
    private let boosting = Mutex<VocabularyBoostingSession?>(nil)

    /// - Parameter vocabulary: Names, products and identifiers to listen for. Empty means no boosting.
    public init(model: Model, vocabulary: [String] = []) {
        self.model = model
        self.vocabulary = vocabulary
        self.name = "parakeet-\(model.rawValue)" + (vocabulary.isEmpty ? "" : "+vocab")
    }

    public func prepare() async throws {
        let models = try await AsrModels.downloadAndLoad(version: model.version)
        try await manager.loadModels(models)
        guard !vocabulary.isEmpty else { return }

        // The CTC model is a separate download (parakeet-ctc-110m, mel spectrogram plus encoder).
        let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let context = CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) })
        let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels)
        boosting.withLock { $0 = session }
    }

    public func transcribe(samples: [Float]) async throws -> Transcript {
        // Decoder state carries over between calls, so each utterance starts fresh.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let start = ContinuousClock.now
        let result = try await manager.transcribe(samples, decoderState: &state)

        var text = result.text
        var replacements: [VocabularyReplacement] = []
        var detected: [String] = []
        if let session = boosting.withLock({ $0 }), let timings = result.tokenTimings,
            let rescored = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)
        {
            text = rescored.text
            detected = rescored.detectedTerms
            replacements = rescored.replacements.compactMap { item in
                guard item.shouldReplace, let term = item.replacementWord else { return nil }
                return VocabularyReplacement(original: item.originalWord, term: term)
            }
        }

        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Transcript(text: text, seconds: seconds, replacements: replacements, detectedTerms: detected)
    }
}
