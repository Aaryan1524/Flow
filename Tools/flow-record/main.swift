@preconcurrency import AVFoundation
import Foundation

// Usage: flow-record [--script evals/script.txt] [--clips evals/clips] [--refs evals/refs]
// Reads one sentence per line. For each: Enter starts recording, Enter stops.
// Saves 16 kHz mono WAV plus a matching reference text. Clips already recorded are skipped.
// Commands at the prompt: s = skip, r = re-record the previous clip, q = quit.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("flow-record: \(message)\n".utf8))
    exit(1)
}

struct Paths {
    var script = "evals/script.txt"
    var clips = "evals/clips"
    var refs = "evals/refs"
}

func parsePaths() -> Paths {
    var paths = Paths()
    var args = CommandLine.arguments.dropFirst()
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { fail("missing value for \(flag)") }
        switch flag {
        case "--script": paths.script = value
        case "--clips": paths.clips = value
        case "--refs": paths.refs = value
        default: fail("unknown option \(flag)")
        }
    }
    return paths
}

let paths = parsePaths()
let scriptPath = paths.script
let clipsDir = paths.clips
let refsDir = paths.refs

/// Collects converted samples from the audio thread.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private let converter: AVAudioConverter
    private let inputRate: Double
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init() throws {
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "flow-record", code: 1, userInfo: [NSLocalizedDescriptionKey: "no usable microphone input"])
        }
        self.converter = converter
        self.inputRate = inFormat.sampleRate
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [self] buffer, _ in
            append(buffer)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputRate) + 32
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
        samples += chunk
        lock.unlock()
    }

    func start() throws {
        lock.lock()
        samples = []
        lock.unlock()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}

func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
}

guard let scriptText = try? String(contentsOfFile: scriptPath, encoding: .utf8) else { fail("cannot read \(scriptPath)") }
let lines = scriptText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
try? FileManager.default.createDirectory(atPath: clipsDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: refsDir, withIntermediateDirectories: true)

guard await requestMicrophone() else {
    fail("microphone access denied. Allow your terminal in System Settings > Privacy & Security > Microphone, then run again.")
}
let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
print("Recording from: \(deviceName)")
print("Speak naturally, as you would when dictating. \(lines.count) sentences.\n")

func name(_ index: Int) -> String { String(format: "clip-%02d", index + 1) }
func clipURL(_ index: Int) -> URL { URL(fileURLWithPath: clipsDir).appendingPathComponent("\(name(index)).wav") }

var index = 0
while index < lines.count {
    if FileManager.default.fileExists(atPath: clipURL(index).path) {
        index += 1
        continue
    }
    print("[\(index + 1)/\(lines.count)] \(lines[index])")
    print("  Enter = start, s = skip, r = redo previous, q = quit: ", terminator: "")
    let command = (readLine() ?? "q").lowercased()
    if command == "q" { break }
    if command == "s" {
        index += 1
        continue
    }
    if command == "r" {
        guard index > 0 else {
            print("  nothing to redo yet\n")
            continue
        }
        try? FileManager.default.removeItem(at: clipURL(index - 1))
        index -= 1
        continue
    }
    if !command.isEmpty {
        print("  unknown command '\(command)'\n")
        continue
    }
    do {
        let recorder = try Recorder()
        try recorder.start()
        print("  recording... press Enter to stop", terminator: "")
        _ = readLine()
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000
        if seconds < 0.5 {
            print("  too short (\(String(format: "%.1f", seconds)) s), try again\n")
            continue
        }
        try recorder.write(samples, to: clipURL(index))
        try (lines[index] + "\n").write(
            to: URL(fileURLWithPath: refsDir).appendingPathComponent("\(name(index)).txt"), atomically: true, encoding: .utf8)
        print("  saved \(String(format: "%.1f", seconds)) s\n")
        index += 1
    } catch {
        fail("recording failed: \(error)")
    }
}
print("Done. Run: swift run -c release flow-eval")
