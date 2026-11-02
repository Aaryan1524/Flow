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
    public static let maxBytes = 60_000
    /// The most words a speaker can take back in one go (not counting the cue itself).
    public static let maxRetractedWords = 12

    /// `nil` means the output is trusted.
    public static func evaluate(input: String, output: String) -> Failure? {
        // Refuse before doing any work on text that is too big to be a dictation.
        guard input.utf8.count <= maxBytes, output.utf8.count <= maxBytes else { return .tooLong }
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
        var sawPlausibleAlignment = false
        for alignment in [left, right].compactMap({ $0 }) where deletionsAreExplained(source, kept: Set(alignment)) {
            sawPlausibleAlignment = true
            if marksOnlyDisappear(source, result, alignment) { return nil }
        }
        return sawPlausibleAlignment ? .symbolOrLineBreakAdded : .deletionNotExplained
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
        /// The punctuation written directly before and after the word, e.g. "(" or ".".
        var leadingMarks: Set<Unicode.Scalar> = []
        var trailingMarkSet: Set<Unicode.Scalar> = []
        /// How many line breaks came between the previous word and this one.
        var newlinesBefore = 0
    }


    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "etc", "jr", "sr", "inc", "ltd", "fig", "figs", "approx", "cf", "st"]
    private static func abbreviationLike(_ core: Substring) -> Bool {
        let lower = core.lowercased()
        if abbreviations.contains(lower) { return true }
        return core.contains(".") && core.allSatisfy { $0.isLetter || $0 == "." }
    }

    private static let leadingMarks: Set<Unicode.Scalar> = ["\"", "\u{201C}", "\u{2018}", "'", "(", "[", "{"]
    private static let sentenceMarks: Set<Unicode.Scalar> = [".", "!", "?", "\u{2026}"]
    private static let clauseMarks: Set<Unicode.Scalar> = [",", ";", ":"]
    private static let trailingMarks: Set<Unicode.Scalar> = [
        ".", ",", ";", ":", "!", "?", "\u{2026}", "\"", "\u{201D}", "\u{2019}", "'", ")", "]", "}",
    ]

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var pendingBreak = true
        var piece = ""
        var newlines = 0
        func flush() {
            guard !piece.isEmpty else { return }
            // Work on unicode scalars in a flat array: stepping back through a long run of identical punctuation
            // one `Character` at a time was quadratic.
            let scalars = Array(piece.unicodeScalars)
            var low = 0
            var high = scalars.count
            while high - low > 1, leadingMarks.contains(scalars[low]) { low += 1 }
            var sentence = false
            var clause = false
            while high - low > 1, trailingMarks.contains(scalars[high - 1]) {
                if sentenceMarks.contains(scalars[high - 1]) { sentence = true }
                if clauseMarks.contains(scalars[high - 1]) { clause = true }
                high -= 1
            }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[low..<high])
            let core = String(view)
            if sentence, abbreviationLike(Substring(core)) { sentence = false }
            let startsSentence = pendingBreak
            result.append(
                Token(
                    text: core, lower: core.lowercased(), endsSentence: sentence, endsClause: clause, startsSentence: startsSentence,
                    leadingMarks: Set(scalars[..<low]), trailingMarkSet: Set(scalars[high...]), newlinesBefore: newlines))
            pendingBreak = sentence
            newlines = 0
            piece = ""
        }
        for character in text {
            if character.isWhitespace {
                flush()
                if character.isNewline {
                    pendingBreak = true
                    newlines += 1
                }
            } else {
                piece.append(character)
            }
        }
        flush()
        return result
    }

    private static func symbolCounts(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for scalar in text.unicodeScalars where !(scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.properties.isWhitespace) {
            counts[Character(scalar), default: 0] += 1
        }
        return counts
    }

    // MARK: - Alignment

    /// Words match if they are identical, or differ only in the case of the first letter of a sentence.
    private static func matches(_ a: Token, _ b: Token) -> Bool {
        if a.text == b.text { return true }
        guard b.startsSentence else { return false }
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

    /// Every kept word may lose punctuation or a line break, but not gain or change one. Otherwise a mark could be
    /// moved to another word ("ready? Or not." becomes "ready. Or not?") while the words stay in order.
    private static func marksOnlyDisappear(_ source: [Token], _ result: [Token], _ alignment: [Int]) -> Bool {
        for (outIndex, inIndex) in alignment.enumerated() {
            let before = source[inIndex]
            let after = result[outIndex]
            guard after.leadingMarks.isSubset(of: before.leadingMarks), after.trailingMarkSet.isSubset(of: before.trailingMarkSet),
                after.newlinesBefore <= before.newlinesBefore
            else { return false }
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
                // A retraction swaps one clause for another; it does not span a comma-separated list.
                guard draft.dropLast().allSatisfy({ !$0.endsClause }) else { continue }
                // A kept negator in front of the draft would end up governing the replacement ("Never [send it to Dana,
                // I mean,] send it to Priya"), which says something the speaker did not.
                var sentenceBegin = run.lowerBound
                while sentenceBegin > 0, !source[sentenceBegin].startsSentence, !source[sentenceBegin - 1].endsSentence { sentenceBegin -= 1 }
                if source[sentenceBegin..<run.lowerBound].contains(where: { isNegator($0.lower) }) { continue }
                // A negator or a number is meaning. If the draft had one, the replacement must say one too.
                if !carriesMeaningAcross(source, draft: draft, afterRun: run.upperBound) { continue }
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
                    // PATCH B: a bare cue may go only where nothing before it is left to be retracted.
                    guard source[..<run.lowerBound].allSatisfy({ fillers.contains($0.lower) }) else { continue }
                    return true
                }
                // Something must remain after the cue to take the draft's place.
                guard run.upperBound < source.count else { continue }
                if draftIsASentence {
                    // PATCH A: the retracted sentence must go whole (its first word starts the sentence).
                    guard cueEndsClause, draft.first?.startsSentence == true else { continue }
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
                    if (draft.count == 1 && sameKind(draft[draft.startIndex], replacement) && (replacement.endsClause || replacement.endsSentence)) || restarts { return true }
                    continue
                }
                // "no" is an ordinary word ("no tumor"), so as a cue it must be fenced by commas on both sides.
                // PATCH F: these cues are ordinary phrases ("will make that, ...", "said never mind, ..."), so a draft
                // may only go when commas sit on both sides of the cue; "I mean" / "or rather" keep one side.
                let ordinaryPhrase: [[String]] = [["no", "wait"], ["wait", "no"], ["make", "that"], ["scratch", "that"], ["strike", "that"], ["never", "mind"]]
                let needsBoth = ordinaryPhrase.contains(cue)
                // PATCH G: a cue that cancels a whole clause must have the draft start at a clause boundary.
                let singleSwap = draft.count == 1 && sameKind(draft[draft.startIndex], replacement)
                if sentenceCues.contains(cue), !singleSwap {
                    let d0 = draft.startIndex
                    guard d0 == 0 || source[d0].startsSentence || source[d0 - 1].endsClause || source[d0 - 1].endsSentence else { continue }
                }
                let fenced = isBareNo ? (cueStartsClause && lastCueWord.endsClause) : (needsBoth ? (cueStartsClause && cueEndsClause) : (cueStartsClause || cueEndsClause))
                let echoes = echoesAfterSwap(source, draft: draft, afterRun: run.upperBound)
                if fenced && (draft.count <= 2 || restarts || echoes) { return true }
                // Unfenced "Maria no wait send it to Marcus" still counts when the words after the cue restate the draft,
                // and "Friday I mean Monday" when one name or number is swapped for another of its kind.
                if !isBareNo, draft.count >= 2, restarts || echoes, !needsBoth || cue == ["no", "wait"] { return true }
                if !isBareNo, !needsBoth || cue == ["no", "wait"], draft.count == 1, sameKind(draft[draft.startIndex], replacement) { return true }
            }
        }
        return false
    }

    private static func isNumberLike(_ token: Token) -> Bool {
        token.lower.contains(where: \.isNumber) || numberWords.contains(token.lower)
    }

    /// If the retracted draft contained a negator or a number, the words that replace it (up to the end of that
    /// sentence) must contain one as well. Otherwise "I do not like the red one, no wait, the blue one" would lose its "not".
    private static func carriesMeaningAcross(_ source: [Token], draft: ArraySlice<Token>, afterRun: Int) -> Bool {
        let draftHasNegator = draft.contains { isNegator($0.lower) }
        let draftHasNumber = draft.contains { isNumberLike($0) }
        guard draftHasNegator || draftHasNumber else { return true }
        var tailHasNegator = false
        var tailHasNumber = false
        var index = afterRun
        while index < source.count {
            tailHasNegator = tailHasNegator || isNegator(source[index].lower)
            tailHasNumber = tailHasNumber || isNumberLike(source[index])
            if source[index].endsSentence { break }
            index += 1
        }
        return (!draftHasNegator || tailHasNegator) && (!draftHasNumber || tailHasNumber)
    }

    /// Plain words that may be said again when a speaker restarts a phrase, so deleting the second copy is harmless.
    private static let restatementWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "by", "from", "it", "that", "this", "them", "him", "her",
        "he", "she", "they", "we", "i", "you", "us", "me", "my", "is", "are", "was", "were", "be", "and", "or", "but", "so",
    ]


    /// PATCH R: "two cups of flour, no wait, three cups of flour": the replacement is the same kind as the draft's first word
    /// (a number phrase for a number phrase, a name for a name) and what follows it repeats the rest of the draft.
    private static func echoesAfterSwap(_ source: [Token], draft: ArraySlice<Token>, afterRun: Int) -> Bool {
        guard afterRun < source.count, let first = draft.first else { return false }
        let replacement = source[afterRun]
        guard sameKind(first, replacement) else { return false }
        func isNum(_ t: Token) -> Bool { t.lower.contains(where: \.isNumber) || numberWords.contains(t.lower) }
        var rest = Array(draft)
        var next = afterRun
        if isNum(first) {
            while let f = rest.first, isNum(f) { rest.removeFirst() }
            while next < source.count, isNum(source[next]) { next += 1 }
        } else {
            rest.removeFirst()
            next += 1
        }
        guard !rest.isEmpty else { return false }
        return rest.indices.allSatisfy { next + $0 < source.count && source[next + $0].lower == rest[$0].lower }
    }

    private static func isNegator(_ word: String) -> Bool {
        let straight = word.replacingOccurrences(of: "\u{2019}", with: "'")
        return ["not", "no", "never", "cannot", "nobody", "nothing", "none", "neither", "nor", "without", "nowhere", "hardly", "barely", "rarely", "scarcely"]
            .contains(straight) || straight.hasSuffix("n't")
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
            guard !isNegator(token.lower), !token.lower.contains(where: \.isNumber), !numberWords.contains(token.lower) else { return false }
            return earlier.contains(token.lower) || restatementWords.contains(token.lower)
        }
    }

    private static func matchesCue(_ source: [Token], at start: Int, cue: [String], within run: Range<Int>) -> Bool {
        guard start + cue.count <= run.upperBound else { return false }
        for (offset, word) in cue.enumerated() where source[start + offset].lower != word { return false }
        return true
    }
}
