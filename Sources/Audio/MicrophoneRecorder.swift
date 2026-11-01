@preconcurrency import AVFoundation
import CoreAudio
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

/// Captures a microphone as 16 kHz mono Float32, the format every `Transcriber` takes.
///
/// Setting up an audio engine takes up to a second, which would swallow the first words of every dictation.
/// So the engine is built ahead of time with `prepare(device:)` and kept stopped (the microphone indicator is
/// off); pressing the key then only has to start it. It is rebuilt when the microphone changes.
///
/// `@unchecked Sendable` because `AVAudioEngine` and `AVAudioConverter` are not Sendable. Shared state is
/// guarded by `lock`; engine building is serialized by `buildLock`.
public final class MicrophoneRecorder: @unchecked Sendable {
    public static let sampleRate = 16_000.0

    private let lock = NSLock()
    private let buildLock = NSLock()

    // Guarded by `lock`
    private var engine: AVAudioEngine?
    private var preparedDevice: AudioDeviceID?
    private var needsRebuild = false
    private var capturing = false
    private var samples: [Float] = []
    private var startedAt: ContinuousClock.Instant?
    private var firstBufferAt: ContinuousClock.Instant?
    private var configurationObserver: NSObjectProtocol?

    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: MicrophoneRecorder.sampleRate, channels: 1, interleaved: false)!

    public init() {}

    public var isRecording: Bool { lock.withLock { capturing } }

    /// Seconds between `start()` and the first audio arriving. A large value means the first words get clipped.
    public var firstBufferDelay: Double? {
        lock.withLock {
            guard let startedAt, let firstBufferAt else { return nil }
            return Self.seconds(startedAt.duration(to: firstBufferAt))
        }
    }

    /// The microphone the prepared engine is bound to, or `nil` if none is ready (or it is the system default).
    public var preparedDeviceID: AudioDeviceID? { lock.withLock { engine == nil || needsRebuild ? nil : preparedDevice } }

    public var isPrepared: Bool { lock.withLock { engine != nil && !needsRebuild } }

    public static var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Name of the input device that would be used by default, for showing the user.
    public static var defaultInputName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown" }

    // MARK: - Preparing

    /// Builds the engine for `device` (or the system default) so a later `start` is quick.
    /// Slow, so call it away from the main thread. Does nothing if an engine for that device is ready.
    public func prepare(device: AudioInputDevice? = nil) throws {
        buildLock.lock()
        defer { buildLock.unlock() }
        let state = lock.withLock { (ready: engine != nil && !needsRebuild, device: preparedDevice, capturing: capturing) }
        if state.capturing { return }
        if state.ready, state.device == device?.id { return }
        try build(device: device)
    }

    private func build(device: AudioInputDevice?) throws {
        let engine = AVAudioEngine()
        // The device must be chosen before the input format is read, because the format belongs to the device.
        if let device { try Self.select(device, on: engine) }
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw RecorderError.noInput }
        // Without this only the first channel is kept, so a mic on input 2 of an audio interface sounds silent.
        converter.downmix = true
        let inputRate = inFormat.sampleRate

        engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: inFormat) { [self] buffer, _ in
            append(buffer, converter: converter, inputRate: inputRate)
        }
        engine.prepare()

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // The microphone changed or was unplugged. The engine is stale; rebuild before the next recording.
            self?.lock.withLock { self?.needsRebuild = true }
        }

        let old = lock.withLock { () -> (AVAudioEngine?, NSObjectProtocol?) in
            let previous = (self.engine, self.configurationObserver)
            self.engine = engine
            self.preparedDevice = device?.id
            self.needsRebuild = false
            self.configurationObserver = observer
            return previous
        }
        if let previousObserver = old.1 { NotificationCenter.default.removeObserver(previousObserver) }
        old.0?.inputNode.removeTap(onBus: 0)
        old.0?.stop()
    }

    private static func select(_ device: AudioInputDevice, on engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else { throw RecorderError.noInput }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw RecorderError.noInput }
    }

    // MARK: - Recording

    /// - Parameter device: the microphone to use. `nil` means whatever the system default is right now.
    public func start(device: AudioInputDevice? = nil) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        // Fast when `prepare` already ran for this device; otherwise this builds the engine now (slow).
        try prepare(device: device)
        guard let engine = lock.withLock({ self.engine }) else { throw RecorderError.noInput }

        lock.withLock {
            samples = []
            firstBufferAt = nil
            startedAt = .now
            capturing = true
        }
        do { try engine.start() } catch {
            lock.withLock {
                capturing = false
                needsRebuild = true
            }
            throw error
        }
    }

    /// Stops capturing and returns everything recorded since `start()`. The engine stays prepared for next time.
    public func stop() -> [Float] {
        let engine = lock.withLock { () -> AVAudioEngine? in
            capturing = false
            return self.engine
        }
        engine?.stop()
        engine?.prepare()
        return lock.withLock {
            let recorded = samples
            samples = []  // don't keep minutes of someone's voice in memory
            return recorded
        }
    }

    /// Stops capturing and throws the audio away.
    public func discard() { _ = stop() }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, inputRate: Double) {
        guard lock.withLock({ capturing }) else { return }
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
        lock.withLock {
            guard capturing else { return }
            if firstBufferAt == nil { firstBufferAt = .now }
            samples += chunk
        }
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
