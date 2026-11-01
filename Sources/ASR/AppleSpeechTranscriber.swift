@preconcurrency import AVFoundation
import FlowKit
import Foundation
import Speech
import Synchronization

/// Apple's on-device speech modules from the Speech framework (macOS 26): `DictationTranscriber`, which is
/// what system dictation uses, and `SpeechTranscriber`, the newer general model.
///
/// A vocabulary is passed as `AnalysisContext.contextualStrings`. The Speech interface puts that property on
/// the module-agnostic context, so nothing there says which module honours it; run both kinds with a
/// vocabulary to see.
public final class AppleSpeechTranscriber: Transcriber {
    public enum Kind: String, CaseIterable, Sendable {
        case dictation
        case speechTranscriber = "speech-transcriber"
    }

    public enum Failure: Error, CustomStringConvertible {
        case localeUnsupported(String)
        case assetsUnavailable(String)
        case noAudioFormat
        case conversion(String)
        case timedOut

        public var description: String {
            switch self {
            case .localeUnsupported(let id): return "Apple speech has no model for \(id)"
            case .assetsUnavailable(let why): return "Apple speech assets unavailable: \(why)"
            case .noAudioFormat: return "Apple speech reported no compatible audio format"
            case .conversion(let why): return "audio conversion failed: \(why)"
            case .timedOut: return "Apple speech did not finish in time"
            }
        }
    }

    public let name: String
    private let kind: Kind
    private let vocabulary: [String]
    private let locale: Locale
    private let timeout: Duration
    private let format = Mutex<AVAudioFormat?>(nil)

    /// - Parameter vocabulary: Passed as contextual strings. Empty means no context.
    public init(kind: Kind, vocabulary: [String] = [], locale: Locale = Locale(identifier: "en-US"), timeout: Duration = .seconds(60)) {
        self.kind = kind
        self.vocabulary = vocabulary
        self.locale = locale
        self.timeout = timeout
        self.name = kind.rawValue + (vocabulary.isEmpty ? "" : "+vocab")
    }

    public func prepare() async throws {
        let module = try await makeModule()
        // Locale models are shared system assets; install them when missing.
        if await AssetInventory.status(forModules: [module]) < .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Failure.noAudioFormat
        }
        format.withLock { $0 = best }
        // Load the model once so the first timed clip does not pay for it.
        try await SpeechAnalyzer(modules: [module], options: Self.options).prepareToAnalyze(in: best)
    }

    public func transcribe(samples: [Float]) async throws -> Transcript {
        guard let target = format.withLock({ $0 }) else { throw Failure.noAudioFormat }
        let buffer = try Self.buffer(from: samples, as: target)

        // Modules and analyzers are single use, so each clip gets its own.
        let start = ContinuousClock.now
        let text: String
        switch kind {
        case .dictation:
            let module = DictationTranscriber(locale: try await resolvedLocale(), preset: .longDictation)
            text = try await run([module], buffer: buffer) {
                Self.join(try await module.results.reduce(into: [String]()) { $0.append(String($1.text.characters)) })
            }
        case .speechTranscriber:
            let module = SpeechTranscriber(locale: try await resolvedLocale(), preset: .transcription)
            text = try await run([module], buffer: buffer) {
                Self.join(try await module.results.reduce(into: [String]()) { $0.append(String($1.text.characters)) })
            }
        }
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Transcript(text: text, seconds: seconds)
    }

    // MARK: - Analysis

    private static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    private func resolvedLocale() async throws -> Locale {
        let supported: Locale?
        switch kind {
        case .dictation: supported = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .speechTranscriber: supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
        guard let supported else { throw Failure.localeUnsupported(locale.identifier) }
        return supported
    }

    private func makeModule() async throws -> any SpeechModule {
        switch kind {
        case .dictation: return DictationTranscriber(locale: try await resolvedLocale(), preset: .longDictation)
        case .speechTranscriber:
            guard SpeechTranscriber.isAvailable else { throw Failure.assetsUnavailable("SpeechTranscriber.isAvailable is false") }
            return SpeechTranscriber(locale: try await resolvedLocale(), preset: .transcription)
        }
    }

    /// Feed one buffer to a fresh analyzer and collect the finished text from `collect`.
    private func run(_ modules: [any SpeechModule], buffer: AVAudioPCMBuffer, collect: @escaping @Sendable () async throws -> String) async throws -> String {
        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: modules, options: Self.options, analysisContext: context)
        let results = Task { try await collect() }
        input.yield(AnalyzerInput(buffer: buffer))
        input.finish()

        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    return try await results.value
                }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Result segments are separate phrases, so join them with single spaces.
    private static func join(_ segments: [String]) -> String {
        segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Audio

    /// 16 kHz mono Float32 samples as a buffer in the format the module wants (16 kHz Int16 at the time of writing).
    private static func buffer(from samples: [Float], as target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = input.floatChannelData?[0]
        else { throw Failure.conversion("cannot allocate the source buffer") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if source == target { return input }

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw Failure.conversion("no converter from \(source) to \(target)")
        }
        let capacity = AVAudioFrameCount((Double(samples.count) * target.sampleRate / source.sampleRate).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure.conversion("cannot allocate the output buffer")
        }
        nonisolated(unsafe) var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw Failure.conversion(error?.localizedDescription ?? "unknown error") }
        return output
    }
}
