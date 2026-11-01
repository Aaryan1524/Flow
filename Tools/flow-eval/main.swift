import ASR
import FlowKit
import FluidAudio
import Foundation

// Usage: flow-eval [--clips DIR] [--refs DIR] [--engines parakeet-v2,parakeet-v3]
//        flow-eval cleanup [--cases FILE] [--cleaners rules,apple,ollama:MODEL] [--verbose]   (see Cleanup.swift)
// Clips are evals/clips/NAME.wav (or .m4a/.caf) with matching reference text evals/refs/NAME.txt.

struct Options {
    var clips = "evals/clips"
    var refs = "evals/refs"
    var engines = ["parakeet-v2", "parakeet-ultra", "parakeet-bark3", "parakeet-bark3-clean"]
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { fail("missing value for \(flag)") }
        switch flag {
        case "--clips": options.clips = value
        case "--refs": options.refs = value
        case "--engines": options.engines = value.split(separator: ",").map(String.init)
        default: fail("unknown option \(flag)")
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("flow-eval: \(message)\n".utf8))
    exit(1)
}

func makeEngine(_ name: String) -> Transcriber {
    for model in FluidAudioTranscriber.Model.allCases where name == "parakeet-\(model.rawValue)" {
        return FluidAudioTranscriber(model: model)
    }
    fail("unknown engine \(name)")
}

struct Clip {
    let name: String
    let url: URL
    let reference: String
}

func loadClips(_ options: Options) -> [Clip] {
    let fm = FileManager.default
    let clipsURL = URL(fileURLWithPath: options.clips)
    let audioExtensions: Set<String> = ["wav", "m4a", "caf", "aiff"]
    guard let files = try? fm.contentsOfDirectory(at: clipsURL, includingPropertiesForKeys: nil) else {
        fail("cannot read \(options.clips)")
    }
    var clips: [Clip] = []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where audioExtensions.contains(file.pathExtension.lowercased()) {
        let name = file.deletingPathExtension().lastPathComponent
        let refURL = URL(fileURLWithPath: options.refs).appendingPathComponent("\(name).txt")
        guard let reference = try? String(contentsOf: refURL, encoding: .utf8) else {
            FileHandle.standardError.write(Data("skipping \(name): no reference at \(refURL.path)\n".utf8))
            continue
        }
        clips.append(Clip(name: name, url: file, reference: reference))
    }
    return clips
}

func run() async {
    let options = parseOptions()
    let clips = loadClips(options)
    guard !clips.isEmpty else { fail("no clips with references found in \(options.clips)") }

    let converter = AudioConverter()
    var samplesByClip: [String: [Float]] = [:]
    for clip in clips {
        do { samplesByClip[clip.name] = try converter.resampleAudioFile(path: clip.url.path) } catch {
            fail("cannot read \(clip.url.lastPathComponent): \(error)")
        }
    }

    print("clips: \(clips.count)\n")
    // "WER" scores the engine's raw text. "+ITN" first turns spoken numbers into digits
    // ("four eight one seven" -> "4817"), which is the form the references use.
    print("engine".padding(toLength: 22, withPad: " ", startingAt: 0) + "WER     +ITN    p50 s   p95 s   RTFx")

    for engineName in options.engines {
        let engine = makeEngine(engineName)
        do { try await engine.prepare() } catch { fail("\(engineName) failed to load: \(error)") }
        // The first call after loading is slower; run it once so timings reflect steady state.
        if let first = clips.first, let samples = samplesByClip[first.name] {
            _ = try? await engine.transcribe(samples: samples)
        }

        var errors = 0.0
        var itnErrors = 0.0
        var words = 0
        var times: [Double] = []
        var audioSeconds = 0.0
        var worst: [(String, Double, String, String)] = []

        for clip in clips {
            guard let samples = samplesByClip[clip.name] else { continue }
            do {
                let transcript = try await engine.transcribe(samples: samples)
                let ref = WER.tokens(clip.reference)
                let normalized = TextNormalizer.shared.normalizeSentence(transcript.text)
                let rawRate = WER.rate(reference: clip.reference, hypothesis: transcript.text)
                let rate = WER.rate(reference: clip.reference, hypothesis: normalized)
                errors += rawRate * Double(ref.count)
                itnErrors += rate * Double(ref.count)
                words += ref.count
                times.append(transcript.seconds)
                audioSeconds += Double(samples.count) / 16_000
                worst.append((clip.name, rate, clip.reference, normalized))
            } catch {
                print("  \(clip.name): \(engineName) failed: \(error)")
            }
        }

        let wer = words == 0 ? 0 : errors / Double(words)
        let itnWer = words == 0 ? 0 : itnErrors / Double(words)
        let totalTime = times.reduce(0, +)
        let rtfx = totalTime == 0 ? 0 : audioSeconds / totalTime
        print(
            engineName.padding(toLength: 22, withPad: " ", startingAt: 0)
                + String(
                    format: "%5.1f%%  %5.1f%%  %6.3f  %6.3f  %5.0fx", wer * 100, itnWer * 100,
                    WER.percentile(times, 0.5), WER.percentile(times, 0.95), rtfx)
        )
        for item in worst.sorted(by: { $0.1 > $1.1 }).prefix(3) where item.1 > 0 {
            print(String(format: "    %@  %.0f%%\n      ref: %@\n      hyp: %@", item.0, item.1 * 100, item.2.trimmingCharacters(in: .whitespacesAndNewlines), item.3))
        }
    }
}

if CommandLine.arguments.dropFirst().first == "cleanup" {
    await runCleanup(Array(CommandLine.arguments.dropFirst(2)))
} else {
    await run()
}
