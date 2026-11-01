import FlowKit
import Foundation

// Vocabulary support for the ASR comparison: what a boosted engine changed compared with the same engine
// without a vocabulary, and whether those changes were right.
//
// The vocabulary comes from the same script the clips were read from, so a good score is partly memorisation.
// The side-effects report is the check on that: clips without any vocabulary term should not get worse, and
// every replacement should put a term where the reference has that term.

/// One clip as one engine transcribed it.
struct ClipOutcome {
    let clip: Clip
    /// The engine's text as returned.
    let raw: String
    /// `raw` with spoken numbers turned into digits, which is the form the references use.
    let text: String
    let replacements: [VocabularyReplacement]
    let detected: [String]
    /// Word errors against the reference, after number conversion.
    let wordErrors: Double
    let referenceWords: Int
}

struct EngineRun {
    let name: String
    let outcomes: [ClipOutcome]
}

func loadVocabulary(_ path: String?) -> [String] {
    guard let path else { return [] }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read vocabulary \(path)") }
    let terms = Vocabulary.parse(text)
    guard !terms.isEmpty else { fail("no terms in \(path)") }
    return terms
}

func termRecall(_ outcomes: [ClipOutcome], terms: [String], useRaw: Bool = false) -> TermRecall.Score {
    outcomes.reduce(TermRecall.Score()) {
        $0 + TermRecall.score(terms: terms, reference: $1.clip.reference, hypothesis: useRaw ? $1.raw : $1.text)
    }
}

private func wordErrorRate(_ outcomes: [ClipOutcome]) -> Double? {
    let words = outcomes.reduce(0) { $0 + $1.referenceWords }
    return words == 0 ? nil : outcomes.reduce(0.0) { $0 + $1.wordErrors } / Double(words)
}

private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }

private func punctuationCount(_ text: String) -> Int { text.filter { ".,;:?!".contains($0) }.count }
private func capitalCount(_ text: String) -> Int { text.filter(\.isUppercase).count }

/// Printed after the main table when `--vocab` is given.
func printVocabularyReport(runs: [EngineRun], terms: [String], verbose: Bool) {
    guard let first = runs.first else { return }
    let hasTerm: [String: Bool] = Dictionary(
        uniqueKeysWithValues: first.outcomes.map { ($0.clip.name, !TermRecall.termsPresent(in: $0.clip.reference, terms: terms).isEmpty) })
    let termClips = hasTerm.values.filter { $0 }.count

    print("\nvocabulary: \(terms.count) terms; \(termClips) of \(first.outcomes.count) clips contain at least one")
    print("WER by clip type (after number conversion). Terms in the reference are what the vocabulary is for;")
    print("clips without any term are the control, where boosting can only do harm.")
    print("engine".padding(toLength: 28, withPad: " ", startingAt: 0) + "clips with terms   clips without terms")
    for run in runs {
        let withTerms = run.outcomes.filter { hasTerm[$0.clip.name] == true }
        let without = run.outcomes.filter { hasTerm[$0.clip.name] != true }
        print(
            run.name.padding(toLength: 28, withPad: " ", startingAt: 0)
                + percent(wordErrorRate(withTerms)).padding(toLength: 19, withPad: " ", startingAt: 0)
                + percent(wordErrorRate(without)))
    }

    for boosted in runs where boosted.name.hasSuffix("+vocab") {
        let baseName = String(boosted.name.dropLast("+vocab".count))
        guard let base = runs.first(where: { $0.name == baseName }) else { continue }
        printSideEffects(base: base, boosted: boosted, terms: terms, hasTerm: hasTerm, verbose: verbose)
    }
}

private func printSideEffects(base: EngineRun, boosted: EngineRun, terms: [String], hasTerm: [String: Bool], verbose: Bool) {
    print("\n== \(boosted.name) compared with \(base.name) ==")
    let baseByClip = Dictionary(uniqueKeysWithValues: base.outcomes.map { ($0.clip.name, $0) })

    var changed = 0
    var better = 0
    var worse = 0
    var changedWithoutTerms = 0
    var replacementsTotal = 0
    var replacementsRight = 0
    var wrongReplacements: [String] = []
    var collateral: [String] = []
    var punctuationBefore = 0
    var punctuationAfter = 0
    var capitalsBefore = 0
    var capitalsAfter = 0
    var detectedClips = 0
    var detectedTotal = 0

    for after in boosted.outcomes {
        guard let before = baseByClip[after.clip.name] else { continue }
        if !after.detected.isEmpty { detectedClips += 1 }
        detectedTotal += after.detected.count

        for replacement in after.replacements {
            replacementsTotal += 1
            // Right means the reference has the term the engine inserted.
            if TermRecall.contains(after.clip.reference, term: replacement.term, caseSensitive: false) {
                replacementsRight += 1
            } else {
                wrongReplacements.append("\(after.clip.name): \"\(replacement.original)\" -> \"\(replacement.term)\"")
            }
        }

        guard before.raw != after.raw else { continue }
        changed += 1
        if hasTerm[after.clip.name] != true { changedWithoutTerms += 1 }
        if after.wordErrors < before.wordErrors { better += 1 } else if after.wordErrors > before.wordErrors { worse += 1 }
        punctuationBefore += punctuationCount(before.raw)
        punctuationAfter += punctuationCount(after.raw)
        capitalsBefore += capitalCount(before.raw)
        capitalsAfter += capitalCount(after.raw)

        // A difference that does not contain a term the engine reported inserting is collateral damage.
        let inserted = after.replacements.map { $0.term.lowercased() }
        let beforeWords = before.raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let afterWords = after.raw.split(whereSeparator: \.isWhitespace).map(String.init)
        for hunk in WordDiff.hunks(beforeWords, afterWords) {
            let afterText = hunk.after.joined(separator: " ").lowercased()
            if !inserted.contains(where: { afterText.contains($0) }) {
                collateral.append("\(after.clip.name): \"\(hunk.before.joined(separator: " "))\" -> \"\(hunk.after.joined(separator: " "))\"")
            }
        }

        if verbose {
            print("  \(after.clip.name)  errors \(Int(before.wordErrors)) -> \(Int(after.wordErrors))")
            print("    ref:   \(after.clip.reference.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("    base:  \(before.text)")
            print("    boost: \(after.text)")
        }
    }

    let sameClips = boosted.outcomes.filter { baseByClip[$0.clip.name] != nil }
    let baseRecall = termRecall(base.outcomes, terms: terms)
    let boostedRecall = termRecall(sameClips, terms: terms)
    print("term recall: \(baseRecall.found)/\(baseRecall.expected) -> \(boostedRecall.found)/\(boostedRecall.expected)"
        + "   exact case: \(baseRecall.foundExactCase) -> \(boostedRecall.foundExactCase)")
    let rawBase = termRecall(base.outcomes, terms: terms, useRaw: true)
    let rawBoosted = termRecall(sameClips, terms: terms, useRaw: true)
    print("term recall on text before number conversion: \(rawBase.found) -> \(rawBoosted.found) of \(rawBoosted.expected)")
    print("transcripts changed: \(changed) of \(sameClips.count)  (fewer word errors: \(better), more: \(worse), same: \(changed - better - worse))")
    print("changed clips with no vocabulary term in the reference: \(changedWithoutTerms)")
    print("replacements applied: \(replacementsTotal), reference has that term: \(replacementsRight), not: \(replacementsTotal - replacementsRight)")
    for line in wrongReplacements { print("  wrong replacement  \(line)") }
    print("differences not explained by a replacement: \(collateral.count)")
    for line in collateral { print("  collateral  \(line)") }
    print("on changed clips, punctuation marks \(punctuationBefore) -> \(punctuationAfter), capital letters \(capitalsBefore) -> \(capitalsAfter)")
    print("spotter heard a vocabulary term in \(detectedClips) clips (\(detectedTotal) detections)")
}
