import ASR
import Cleanup
import FlowKit
import FluidAudio
import Foundation

// Usage: flow-eval pipeline [--clips DIR] [--refs DIR] [--engine parakeet-v2] [--cleaners rules,apple,ollama:MODEL]
// Runs your recordings through speech-to-text, number conversion, then each cleaner (guard failures fall back to rules),
// so cleanup is judged on real transcripts instead of typed test sentences.
//
// Clip groups follow evals/script.txt: 1-30 plain speech, 31-36 spoken corrections, 37-40 requests to an AI, 41-42 long.
private let plainClips = 1...30
private let correctionClips = 31...36
private let requestClips = 37...40
private let longClips = 41...42

private struct Transcribed {
    let number: Int
    let clip: Clip
    let text: String
    let asrSeconds: Double
}

private struct Cleaned {
    let source: Transcribed
    let text: String
    let seconds: Double
    let guardFailure: String?
    let preservation: Preservation.Report
}

func runPipeline(_ arguments: [String]) async {
    var paths = Options()
    var engineName = "parakeet-v2"
    var cleanerSpecs = ["rules", "apple", "ollama:gemma3:4b", "ollama:qwen3:4b-instruct"]
    var args = arguments[...]
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { fail("missing value for \(flag)") }
        switch flag {
        case "--clips": paths.clips = value
        case "--refs": paths.refs = value
        case "--engine": engineName = value
        case "--cleaners": cleanerSpecs = value.split(separator: ",").map(String.init)
        default: fail("unknown option \(flag)")
        }
    }

    let clips = loadClips(paths)
    guard !clips.isEmpty else { fail("no clips with references found in \(paths.clips)") }

    // Speech to text, once per clip.
    let engine = makeEngine(engineName)
    do { try await engine.prepare() } catch { fail("\(engineName) failed to load: \(error)") }
    let converter = AudioConverter()
    var transcribed: [Transcribed] = []
    for (index, clip) in clips.enumerated() {
        guard let number = Int(clip.name.split(separator: "-").last ?? "") else { continue }
        let samples: [Float]
        do { samples = try converter.resampleAudioFile(path: clip.url.path) } catch { fail("cannot read \(clip.name): \(error)") }
        if index == 0 { _ = try? await engine.transcribe(samples: samples) }  // warm-up
        do {
            let transcript = try await engine.transcribe(samples: samples)
            transcribed.append(
                Transcribed(number: number, clip: clip, text: TextNormalizer.shared.normalizeSentence(transcript.text), asrSeconds: transcript.seconds))
        } catch { print("\(clip.name): \(engineName) failed: \(error)") }
    }

    let plain = transcribed.filter { plainClips.contains($0.number) }
    let baseline = aggregateWER(plain.map { ($0.clip.reference, $0.text) })
    print("engine: \(engineName) + number conversion, \(transcribed.count) clips (\(plain.count) plain)")
    print(String(format: "no cleanup: WER on plain clips %.1f%%\n", baseline * 100))

    let rules = RulesCleaner()
    var table: [String] = []
    var details: [String] = []

    for spec in cleanerSpecs {
        let cleaner = makeCleaner(spec)
        do { try await cleaner.prepare() } catch {
            table.append("\(pad(spec, 26))unavailable: \(error.localizedDescription)")
            continue
        }
        if let first = transcribed.first { _ = try? await cleaner.clean(first.text) }  // warm-up

        var results: [Cleaned] = []
        for item in transcribed {
            let start = ContinuousClock.now
            let output = try? await cleaner.clean(item.text)
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let verdict = output.map { CleanupGuard.standard.evaluate(raw: item.text, cleaned: $0) }
            // Same rule as the app: use the AI output only if the guard trusts it.
            let final: String
            if let output, verdict?.isTrustworthy == true { final = output } else { final = rules.cleaned(item.text) }
            results.append(
                Cleaned(
                    source: item, text: final, seconds: seconds, guardFailure: verdict?.failure.map { "\($0)" } ?? (output == nil ? "error" : nil),
                    preservation: Preservation.check(input: item.text, output: final)))
        }

        let plainResults = results.filter { plainClips.contains($0.source.number) }
        let wer = aggregateWER(plainResults.map { ($0.source.clip.reference, $0.text) })
        let worse = plainResults.filter {
            WER.rate(reference: $0.source.clip.reference, hypothesis: $0.text) > WER.rate(reference: $0.source.clip.reference, hypothesis: $0.source.text)
        }
        let trips = results.filter { $0.guardFailure != nil }.count
        let lossy = results.filter { !$0.preservation.isClean }
        let cleanupTimes = results.map(\.seconds)
        let totals = results.map { $0.seconds + $0.source.asrSeconds }
        let longTotal = results.filter { longClips.contains($0.source.number) }.map { $0.seconds + $0.source.asrSeconds }.max() ?? 0

        table.append(
            pad(spec, 26)
                + String(
                    format: "%5.1f%%   %2d    %2d     %2d     %6.0f %6.0f   %6.0f   %6.0f",
                    wer * 100, worse.count, trips, lossy.count,
                    WER.percentile(cleanupTimes, 0.5) * 1000, WER.percentile(cleanupTimes, 0.95) * 1000,
                    WER.percentile(totals, 0.95) * 1000, longTotal * 1000))

        details.append("\n== \(spec) ==")
        for item in worse {
            details.append(
                "  worse than no cleanup: clip-\(item.source.number)\n    ref:     \(item.source.clip.reference.trimmingCharacters(in: .whitespacesAndNewlines))"
                    + "\n    before:  \(item.source.text)\n    after:   \(item.text)")
        }
        for item in lossy {
            var what: [String] = []
            if !item.preservation.lostIdentifiers.isEmpty { what.append("identifier changed: " + item.preservation.lostIdentifiers.joined(separator: ", ")) }
            if !item.preservation.droppedWords.isEmpty { what.append("words dropped: " + item.preservation.droppedWords.joined(separator: ", ")) }
            if !item.preservation.changedNumbers.isEmpty { what.append("number changed: " + item.preservation.changedNumbers.joined(separator: ", ")) }
            details.append("  LOSS clip-\(item.source.number) (\(what.joined(separator: "; ")))\n    before:  \(item.source.text)\n    after:   \(item.text)")
        }
        for item in results where correctionClips.contains(item.source.number) || requestClips.contains(item.source.number) {
            let kind = correctionClips.contains(item.source.number) ? "correction" : "request"
            let note = item.guardFailure.map { "  [guard: \($0), used rules]" } ?? ""
            details.append("  \(kind) clip-\(item.source.number)\(note)\n    before:  \(item.source.text)\n    after:   \(item.text)")
        }
    }

    print(pad("cleaner", 26) + "WER 1-30  worse  trips  loss   cleanup ms (p50 p95)  total p95  long clips")
    table.forEach { print($0) }
    print("\nworse = plain clips where cleanup scored worse than no cleanup. trips = guard rejections (rules used instead).")
    print("loss = identifiers or numbers changed, or ordinary words dropped. total = speech-to-text + cleanup. long = slowest of clips 41-42 (ms).")
    details.forEach { print($0) }
}
