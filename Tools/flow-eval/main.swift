import ASR
import FlowKit
import FluidAudio
import Foundation

// Usage: flow-eval [--clips DIR] [--refs DIR] [--engines parakeet-v2,parakeet-v3] [--vocab FILE] [--verbose]
//        Engines: parakeet-{v2,v3,ultra,bark3,bark3-clean}, dictation, speech-transcriber (Apple Speech framework).
//        A "+vocab" suffix (parakeet-v2+vocab, dictation+vocab) gives that engine the terms in FILE.
//        For parakeet engines, "+vocab@0.7" also sets how close in spelling a term must be to replace a word.
//        With --vocab the table gains a term-recall column and a report on what boosting changed.
//        flow-eval cleanup [--cases FILE] [--cleaners rules,apple,ollama:MODEL] [--verbose]   (see Cleanup.swift)
//        flow-eval pipeline [--clips DIR] [--refs DIR] [--engine NAME] [--cleaners ...]       (see Pipeline.swift)
// Clips are evals/clips/NAME.wav (or .m4a/.caf) with matching reference text evals/refs/NAME.txt.

struct Options {
    var clips = "evals/clips"
    var refs = "evals/refs"
    var engines = ["parakeet-v2", "parakeet-ultra", "parakeet-bark3", "parakeet-bark3-clean"]
    var vocab: String?
    var verbose = false
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    while let flag = args.popFirst() {
        if flag == "--verbose" {
            options.verbose = true
            continue
        }
        guard let value = args.popFirst() else { fail("missing value for \(flag)") }
        switch flag {
        case "--clips": options.clips = value
        case "--refs": options.refs = value
        case "--engines": options.engines = value.split(separator: ",").map(String.init)
        case "--vocab": options.vocab = value
        default: fail("unknown option \(flag)")
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("flow-eval: \(message)\n".utf8))
    exit(1)
}

/// `NAME` runs an engine as is; `NAME+vocab` also gives it `vocabulary`; `NAME+vocab@0.7` sets FluidAudio's
/// minimum spelling similarity for a replacement.
func makeEngine(_ name: String, vocabulary: [String] = []) -> Transcriber {
    var base = name
    var boosted = false
    var minSimilarity: Float?
    if let range = name.range(of: "+vocab") {
        base = String(name[..<range.lowerBound])
        boosted = true
        let rest = name[range.upperBound...]
        if rest.hasPrefix("@") {
            guard let value = Float(rest.dropFirst()) else { fail("bad similarity in \(name)") }
            minSimilarity = value
        } else if !rest.isEmpty {
            fail("unknown engine \(name)")
        }
    }
    if boosted && vocabulary.isEmpty { fail("\(name) needs --vocab FILE") }
    let terms = boosted ? vocabulary : []
    for model in FluidAudioTranscriber.Model.allCases where base == "parakeet-\(model.rawValue)" {
        return FluidAudioTranscriber(model: model, vocabulary: terms, minSimilarity: minSimilarity)
    }
    if minSimilarity != nil { fail("@similarity only applies to parakeet engines: \(name)") }
    for kind in AppleSpeechTranscriber.Kind.allCases where base == kind.rawValue {
        return AppleSpeechTranscriber(kind: kind, vocabulary: terms)
    }
    fail("unknown engine \(name)")
}

/// Resident memory the process is accountable for, in megabytes.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
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
    let vocabulary = loadVocabulary(options.vocab)

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
    // "recall" is the share of vocabulary terms in the references that the engine's text (after the same
    // number conversion as +ITN) contains as a whole word, ignoring case; "exact" also requires the term's
    // own capitalisation. Both are counted once per clip and term. "load MB" is how much the process grew
    // while loading the engine, so it is only clean for the first engine in a run.
    let recallHeader = vocabulary.isEmpty ? "" : "recall            exact             "
    print("engine".padding(toLength: 28, withPad: " ", startingAt: 0) + "WER     +ITN    " + recallHeader + "p50 s   p95 s   RTFx    load MB")

    var runs: [EngineRun] = []
    for engineName in options.engines {
        let engine = makeEngine(engineName, vocabulary: vocabulary)
        let memoryBefore = footprintMB()
        do { try await engine.prepare() } catch { fail("\(engineName) failed to load: \(error)") }
        // The first call after loading is slower; run it once so timings reflect steady state.
        if let first = clips.first, let samples = samplesByClip[first.name] {
            _ = try? await engine.transcribe(samples: samples)
        }
        let loadedMB = footprintMB() - memoryBefore

        var errors = 0.0
        var itnErrors = 0.0
        var words = 0
        var times: [Double] = []
        var audioSeconds = 0.0
        var worst: [(String, Double, String, String)] = []
        var outcomes: [ClipOutcome] = []

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
                outcomes.append(
                    ClipOutcome(
                        clip: clip, raw: transcript.text, text: normalized, replacements: transcript.replacements,
                        detected: transcript.detectedTerms, wordErrors: rate * Double(ref.count), referenceWords: ref.count))
            } catch {
                print("  \(clip.name): \(engineName) failed: \(error)")
            }
        }

        let wer = words == 0 ? 0 : errors / Double(words)
        let itnWer = words == 0 ? 0 : itnErrors / Double(words)
        let totalTime = times.reduce(0, +)
        let rtfx = totalTime == 0 ? 0 : audioSeconds / totalTime
        var recallColumns = ""
        if !vocabulary.isEmpty {
            let score = termRecall(outcomes, terms: vocabulary)
            recallColumns =
                String(format: "%3.0f%% %2d/%-2d      ", score.recall * 100, score.found, score.expected)
                + String(format: "%3.0f%% %2d/%-2d      ", score.exactCaseRecall * 100, score.foundExactCase, score.expected)
        }
        print(
            engineName.padding(toLength: 28, withPad: " ", startingAt: 0)
                + String(format: "%5.1f%%  %5.1f%%  ", wer * 100, itnWer * 100)
                + recallColumns
                + String(format: "%6.3f  %6.3f  %5.0fx  %7.0f", WER.percentile(times, 0.5), WER.percentile(times, 0.95), rtfx, loadedMB)
        )
        for item in worst.sorted(by: { $0.1 > $1.1 }).prefix(3) where item.1 > 0 {
            print(String(format: "    %@  %.0f%%\n      ref: %@\n      hyp: %@", item.0, item.1 * 100, item.2.trimmingCharacters(in: .whitespacesAndNewlines), item.3))
        }
        if options.verbose && !vocabulary.isEmpty {
            print("    terms missed: " + missedTerms(outcomes, terms: vocabulary).joined(separator: ", "))
        }
        runs.append(EngineRun(name: engineName, outcomes: outcomes))
    }

    if !vocabulary.isEmpty { printVocabularyReport(runs: runs, terms: vocabulary, verbose: options.verbose) }
}

switch CommandLine.arguments.dropFirst().first {
case "cleanup": await runCleanup(Array(CommandLine.arguments.dropFirst(2)))
case "pipeline": await runPipeline(Array(CommandLine.arguments.dropFirst(2)))
default: await run()
}
