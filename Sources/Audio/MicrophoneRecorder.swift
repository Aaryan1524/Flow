@preconcurrency import AVFoundation
import Foundation

public enum RecorderError: Error, LocalizedError {
    case noInput
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .noInput: return "no usable microphone input"
        case .alreadyRecording: return "already recording"
        }
    }
}

/// Captures the default microphone as 16 kHz mono Float32, the format every `Transcriber` takes.
///
/// `@unchecked Sendable` because `AVAudioConverter` is not Sendable. It is only touched from the audio
/// thread after `start()` returns, and `samples` is guarded by `lock`.
public final class MicrophoneRecorder: @unchecked Sendable {
    public static let sampleRate = 16_000.0

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var startedAt: ContinuousClock.Instant?
    private var firstBufferAt: ContinuousClock.Instant?

    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: MicrophoneRecorder.sampleRate, channels: 1, interleaved: false)!

    public init() {}

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine != nil
    }

    /// Seconds between `start()` and the first audio arriving. A large value means the first words get clipped.
    public var firstBufferDelay: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt, let firstBufferAt else { return nil }
        return Self.seconds(startedAt.duration(to: firstBufferAt))
    }

    public static var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Name of the input device that would be used, for showing the user.
    public static var defaultInputName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown" }

    public func start() throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let engine = AVAudioEngine()
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.noInput
        }
        // Without this only the first channel is kept, so a mic on input 2 of an audio interface sounds silent.
        converter.downmix = true
        let inputRate = inFormat.sampleRate
        lock.lock()
        samples = []
        firstBufferAt = nil
        startedAt = .now
        lock.unlock()

        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [self] buffer, _ in
            append(buffer, converter: converter, inputRate: inputRate)
        }
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        lock.lock()
        self.engine = engine
        lock.unlock()
    }

    /// Stops capturing and returns everything recorded since `start()`.
    public func stop() -> [Float] {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        lock.lock()
        defer { lock.unlock() }
        let recorded = samples
        samples = []  // don't keep minutes of someone's voice in memory
        return recorded
    }

    /// Stops capturing and throws the audio away.
    public func discard() { _ = stop() }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, inputRate: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var supplied = false  // the converter calls the block synchronously
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock()
        if firstBufferAt == nil { firstBufferAt = .now }
        samples += chunk
        lock.unlock()
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension MicrophoneRecorder {
    /// Writes 16-bit PCM WAV at 16 kHz mono.
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
