import Foundation

/// The strictest layer of the cleanup safety net. It trusts an AI edit only if the AI did nothing but DELETE
/// words a speaker took back.
///
/// This is deliberately narrow. A check that has to recognise every legitimate rewrite (numbers, joins and
/// splits, reworded text) can be fooled by an illegitimate edit that looks like one. Here the output must be
/// the input minus some words, so an answer, a changed number, a swapped name or an added symbol cannot get
/// through: there is nothing to add. What remains to judge is only which words were deleted.
///
/// The input is the rules-cleaned text, so fillers, stutters and punctuation are already handled. The AI's one
/// job is to resolve self-corrections, so deleting a repeated word is not allowed here: the rules did that, and
/// "bye bye", "very very" or "If you know, you know" are not stutters.
public enum DeleteOnlyCheck {
    public enum Failure: Error, Equatable, Sendable {
        /// Too long to check cheaply, so not trusted.
        case tooLong
        /// The output is not the input with some words removed (something was added, changed or reordered).
        case notOnlyDeletions
        /// A letter changed case somewhere other than the first letter of a sentence.
        case caseChanged
        /// The output has a symbol or line break the input did not have.
        case symbolOrLineBreakAdded
        /// Words were deleted that are not a filler or a clearly retracted phrase.
        case deletionNotExplained
    }

    /// Longer text is not checked, and so not trusted.
    public static let maxWords = 2000
    /// The most words a speaker can take back in one go (not counting the cue itself).
    public static let maxRetractedWords = 12

    /// `nil` means the output is trusted.
    public static func evaluate(input: String, output: String) -> Failure? {
        let source = tokens(input)
        let result = tokens(output)
        guard source.count <= maxWords else { return .tooLong }

        // Symbols and line breaks can only go away, never appear or multiply.
        let inSymbols = symbolCounts(input)
        for (symbol, count) in symbolCounts(output) where count > inSymbols[symbol, default: 0] {
            return .symbolOrLineBreakAdded
        }
        if output.filter(\.isNewline).count > input.filter(\.isNewline).count { return .symbolOrLineBreakAdded }

        // Every output word is an input word, in order. Try the earliest and the latest way of lining them up;
        // either one that explains the deletions is enough.
        let left = align(source, result)
        let right = align(Array(source.reversed()), Array(result.reversed()))
            .map { $0.reversed().map { source.count - 1 - $0 } }
        guard left != nil || right != nil else {
            // Tell a pure case problem apart from added or changed words.
            let folded = { (list: [Token]) in list.map { $0.text.lowercased() } }
            return isSubsequence(folded(result), of: folded(source)) ? .caseChanged : .notOnlyDeletions
        }
        for alignment in [left, right].compactMap({ $0 }) where deletionsAreExplained(source, kept: Set(alignment)) {
            return nil
        }
        return .deletionNotExplained
    }

    public static func isTrusted(input: String, output: String) -> Bool { evaluate(input: input, output: output) == nil }

    // MARK: - Tokens

    struct Token {
        /// The word as written, without surrounding sentence punctuation. Symbols inside it (-5, C++, $25, I'll) stay.
        let text: String
        let lower: String
        /// Ends with . ! ? or an ellipsis.
        let endsSentence: Bool
        /// Ends with , ; or :
        let endsClause: Bool
        /// First word of a sentence or after a line break.
        var startsSentence: Bool
    }

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var pendingBreak = true
        var piece = ""
        func flush() {
            guard !piece.isEmpty else { return }
            var core = Substring(piece)
            while let first = core.first, "\"“‘'([{".contains(first), core.count > 1 { core = core.dropFirst() }
            var sentence = false
            var clause = false
            while let last = core.last, ".,;:!?…\"”’')]}".contains(last), core.count > 1 {
                if ".!?…".contains(last) { sentence = true }
                if ",;:".contains(last) { clause = true }
                core = core.dropLast()
            }
            let startsSentence = pendingBreak
            result.append(Token(text: String(core), lower: core.lowercased(), endsSentence: sentence, endsClause: clause, startsSentence: startsSentence))
            pendingBreak = sentence
            piece = ""
        }
        for character in text {
            if character.isWhitespace {
                flush()
                if character.isNewline { pendingBreak = true }
            } else {
                piece.append(character)
            }
        }
        flush()
        return result
    }

    private static func symbolCounts(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for character in text where !(character.isLetter || character.isNumber || character.isWhitespace) {
            counts[character, default: 0] += 1
        }
        return counts
    }

    // MARK: - Alignment

    /// Words match if they are identical, or differ only in the case of the first letter of a sentence.
    private static func matches(_ a: Token, _ b: Token) -> Bool {
        if a.text == b.text { return true }
        guard a.startsSentence || b.startsSentence else { return false }
        return a.lower == b.lower && a.text.dropFirst() == b.text.dropFirst()
    }

    /// For each output word, the input position it came from, matching as early as possible. `nil` if the
    /// output is not an in-order subset of the input.
    private static func align(_ source: [Token], _ result: [Token]) -> [Int]? {
        var positions: [Int] = []
        var next = 0
        for word in result {
            while next < source.count, !matches(source[next], word) { next += 1 }
            guard next < source.count else { return nil }
            positions.append(next)
            next += 1
        }
        return positions
    }

    private static func isSubsequence(_ small: [String], of big: [String]) -> Bool {
        var next = 0
        for word in small {
            while next < big.count, big[next] != word { next += 1 }
            guard next < big.count else { return false }
            next += 1
        }
        return true
    }

    // MARK: - Which deletions are allowed

    private static let fillers: Set<String> = ["um", "uh", "uhh", "umm", "uhm", "er", "erm", "hmm", "hm", "ah"]

    /// Phrases that take back what was just said. A bare "sorry" or "actually" is not here: both are ordinary words.
    private static let cues: [[String]] = [
        ["actually", "make", "that"], ["scratch", "that"], ["strike", "that"], ["never", "mind"], ["no", "wait"],
        ["wait", "no"], ["i", "mean"], ["or", "rather"], ["make", "that"], ["no"],
    ]

    private static func deletionsAreExplained(_ source: [Token], kept: Set<Int>) -> Bool {
        var index = 0
        while index < source.count {
            guard !kept.contains(index) else {
                index += 1
                continue
            }
            var end = index
            while end < source.count, !kept.contains(end) { end += 1 }
            guard isAllowedRun(source, index..<end) else { return false }
            index = end
        }
        return true
    }

    private static func isAllowedRun(_ source: [Token], _ run: Range<Int>) -> Bool {
        let words = source[run]
        if words.allSatisfy({ fillers.contains($0.lower) }) { return true }
        return isRetraction(source, run)
    }

    /// Cues that retract the whole sentence before them when they form a sentence of their own.
    private static let sentenceCues: [[String]] = [["scratch", "that"], ["strike", "that"], ["never", "mind"]]

    /// Everyday words that also mark a correction ("Tuesday, actually Wednesday"). They only count as a swap of one
    /// word for another of the same kind, straight after a comma.
    private static let softCues: [[String]] = [["actually"], ["sorry"], ["oops"], ["correction"]]

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million",
    ]

    /// Both numbers, or both capitalised names: the shape of a swapped value.
    private static func sameKind(_ a: Token, _ b: Token) -> Bool {
        func isNumber(_ t: Token) -> Bool { t.lower.contains(where: \.isNumber) || numberWords.contains(t.lower) }
        if isNumber(a) && isNumber(b) { return true }
        return !isNumber(a) && !isNumber(b) && a.text.first?.isUppercase == true && b.text.first?.isUppercase == true
    }

    /// `draft + cue (+ fillers)` with something left after it to take the draft's place. Normally all inside one
    /// sentence; the exception is "Add milk. Scratch that. Add oat milk.", where a cue that is a sentence on its own
    /// takes back the one sentence before it.
    private static func isRetraction(_ source: [Token], _ run: Range<Int>) -> Bool {
        guard run.count <= maxRetractedWords + 4 else { return false }

        for start in run {
            for cue in cues + softCues where matchesCue(source, at: start, cue: cue, within: run) {
                let cueEnd = start + cue.count
                // Words deleted after the cue may only restate the draft ("Dana, no wait, [send it to] Priya").
                guard restatesTheDraft(source, tail: cueEnd..<run.upperBound, cueStart: start) else { continue }
                // The cue is one phrase, and nothing after it may end a sentence early.
                guard source[start..<(cueEnd - 1)].allSatisfy({ !$0.endsSentence }),
                    source[cueEnd..<run.upperBound].dropLast().allSatisfy({ !$0.endsSentence })
                else { continue }

                // A leading "Um," is a filler, not part of what was retracted.
                let fullDraft = source[run.lowerBound..<start]
                let draft = fullDraft.drop(while: { fillers.contains($0.lower) })
                guard draft.count <= maxRetractedWords else { continue }
                // The draft is one sentence. Only its last word may end it, and only for a cue sentence of its own.
                guard draft.dropLast().allSatisfy({ !$0.endsSentence }) else { continue }
                let draftIsASentence = draft.last?.endsSentence == true
                let asSentence = source[start].startsSentence && sentenceCues.contains(cue)
                guard !draftIsASentence || asSentence else { continue }

                let cueStartsClause = start == 0 || source[start].startsSentence || source[start - 1].endsClause
                    || source[start - 1].endsSentence
                let lastCueWord = source[cueEnd - 1]
                let cueEndsClause = lastCueWord.endsClause || lastCueWord.endsSentence
                let isSoft = softCues.contains(cue)
                let isBareNo = cue == ["no"]

                if draft.isEmpty {
                    // Nothing before the cue: only the cue itself goes. It must be closed off by a comma or full
                    // stop ("Scratch that, ..."), so "Make that sauce" and "Never mind the cost" stay.
                    // A bare "No," at the start is a real answer and "Sorry, ..." is an apology, not a retraction.
                    guard !isBareNo, !isSoft, cueEndsClause, cueStartsClause else { continue }
                    return true
                }
                // Something must remain after the cue to take the draft's place.
                guard run.upperBound < source.count else { continue }
                if draftIsASentence {
                    // "Add milk to the list. Scratch that. Add oat milk.": the cue must close its own sentence.
                    guard cueEndsClause else { continue }
                    return true
                }
                // Within a sentence the cue cannot be the end of it.
                guard !lastCueWord.endsSentence else { continue }
                let replacement = source[run.upperBound]
                let restarts = draft.prefix(3).contains { $0.lower == replacement.lower }

                if isSoft {
                    // "Tuesday, actually Wednesday": after a comma, one word swapped for another of its kind,
                    // or the draft restated ("room 204, correction, room 240").
                    guard source[start - 1].endsClause, start > run.lowerBound else { continue }
                    if (draft.count == 1 && sameKind(draft[draft.startIndex], replacement)) || restarts { return true }
                    continue
                }
                // "no" is an ordinary word ("no tumor"), so as a cue it must be fenced by commas on both sides.
                let fenced = isBareNo ? (cueStartsClause && lastCueWord.endsClause) : (cueStartsClause || cueEndsClause)
                if fenced && (draft.count <= 2 || restarts) { return true }
                // Unfenced "Maria no wait send it to Marcus" still counts when the words after the cue restate the draft,
                // and "Friday I mean Monday" when one name or number is swapped for another of its kind.
                if !isBareNo, draft.count >= 2, restarts { return true }
                if !isBareNo, draft.count == 1, sameKind(draft[draft.startIndex], replacement) { return true }
            }
        }
        return false
    }

    /// Plain words that may be said again when a speaker restarts a phrase, so deleting the second copy is harmless.
    private static let restatementWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "by", "from", "it", "that", "this", "them", "him", "her",
        "he", "she", "they", "we", "i", "you", "us", "me", "my", "is", "are", "was", "were", "be", "and", "or", "but", "so",
    ]

    private static func isNegator(_ word: String) -> Bool {
        ["not", "no", "never", "cannot", "nobody", "nothing", "none", "neither", "nor", "without"].contains(word) || word.hasSuffix("n't")
    }

    /// What follows a cue inside the deleted run: fillers, or a few words already said earlier in the sentence or
    /// plain function words. Never a negator or a number, which carry meaning.
    private static func restatesTheDraft(_ source: [Token], tail: Range<Int>, cueStart: Int) -> Bool {
        guard tail.count <= 6 else { return false }
        var sentenceStart = cueStart
        while sentenceStart > 0, !source[sentenceStart].startsSentence, !source[sentenceStart - 1].endsSentence { sentenceStart -= 1 }
        let earlier = Set(source[sentenceStart..<cueStart].map(\.lower))
        return source[tail].allSatisfy { token in
            if fillers.contains(token.lower) { return true }
            guard !isNegator(token.lower), !token.lower.contains(where: \.isNumber) else { return false }
            return earlier.contains(token.lower) || restatementWords.contains(token.lower)
        }
    }

    private static func matchesCue(_ source: [Token], at start: Int, cue: [String], within run: Range<Int>) -> Bool {
        guard start + cue.count <= run.upperBound else { return false }
        for (offset, word) in cue.enumerated() where source[start + offset].lower != word { return false }
        return true
    }
}
