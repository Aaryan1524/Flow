import Foundation

/// Decides whether an AI cleaner's output can be trusted as an edit of its input.
///
/// A faithful cleanup only deletes words (fillers, repeats, corrected-away phrases) and changes
/// punctuation, so the output is almost a subsequence of the input. An answer, an email, a
/// refusal or a chatty preface adds words the speaker never said, or throws most of the input
/// away. When the guard says no, callers use the deterministic rules output instead.
///
/// One call to `evaluate` is the whole decision: it also checks that negations, numbers and
/// identifiers survived and that no list markers, markdown, emoji or question marks were added.
public struct CleanupGuard: Sendable {
    public enum Failure: Sendable, Equatable {
        /// Nothing came back although the input had words.
        case emptyOutput
        /// Words the speaker said are missing: a summary, an answer, a refusal, or a truncation.
        case tooShort
        /// More words than the input: added content or duplicated text.
        case tooLong
        /// Too many output words were not in the input, in order.
        case addedContent
        /// Starts or ends like a chat reply ("Sure, here is...", "I'm sorry...").
        case chattyFraming
        /// A "not", "never", "no" or n't form was dropped, added or swapped.
        case negationChanged
        /// A number in the dictation has another value in the output, or the output has a number nobody said.
        case numberChanged
        /// An identifier (camelCase, snake_case, S3) changed spelling or case.
        case identifierChanged
        /// List markers, markdown, emoji, or a question or exclamation mark the speaker never dictated.
        case formatChanged
    }

    public struct Verdict: Sendable, Equatable {
        public let failure: Failure?
        /// Output words (a number counts as one) divided by the input words a plain edit would keep.
        public let lengthRatio: Double
        /// Output words (a number counts as one) that do not appear in the input, in order.
        public let addedWords: Int

        public var isTrustworthy: Bool { failure == nil }
    }

    /// Floor for output/input length when the speaker corrects themselves ("scratch that", "actually").
    /// Corrections can drop much of a short sentence, so the floor rises from 0.3 at 12 words to 0.55 at 30.
    public var shortInputMinRatio = 0.3
    public var longInputMinRatio = 0.55
    /// Floor when there is no correction: only fillers and repeats should go, so losing more is suspect.
    public var plainMinRatio = 0.75
    /// Inputs of up to this many words must come back with every word that is not a filler, a repeat or part
    /// of a correction. Longer ones may lose up to `1 - plainMinRatio` of their words.
    public var strictInputWords = 12
    public var maxLengthRatio = 1.3
    /// Share of output words allowed to be new. Below 10 output words this rounds down to none.
    public var addedWordFraction = 0.1
    /// Most new words allowed whatever the length, so an answer can't hide in a long dictation.
    /// The pipeline calls the guard per chunk, which keeps this cap proportional to the text.
    public var maxAddedWords = 3

    public init() {}

    public static let standard = CleanupGuard()

    public func isTrustworthy(raw: String, cleaned: String) -> Bool {
        evaluate(raw: raw, cleaned: cleaned).isTrustworthy
    }

    /// `before` and `after` are the raw dictation around a chunk. A correction can begin in one chunk and
    /// end in the next ("send it to Maria no wait" / "send it to Marcus"); with the neighbouring text the
    /// guard still recognises it. They are only used to recognise corrections, never to excuse the chunk's own words.
    public func evaluate(raw: String, cleaned: String, before: String = "", after: String = "") -> Verdict {
        let output = Self.prepare(cleaned)
        let outputWords = Set(output.filter { $0.number == nil }.map(\.text))
        let input = Self.analyze(raw, matching: outputWords, before: before, after: after)
        let spoken = input.filter { !$0.isFiller }.map(\.text)

        if output.isEmpty {
            return Verdict(failure: spoken.isEmpty ? nil : .emptyOutput, lengthRatio: 0, addedWords: 0)
        }
        if Self.hasChattyFraming(input: spoken, output: output.map(\.text)) {
            return Verdict(failure: .chattyFraming, lengthRatio: 0, addedWords: 0)
        }

        let expectation = Self.expectation(from: input, cleaned: cleaned)

        // Words: how much of the input is in the output, and how much of the output is not in the input.
        var vocabulary = Vocabulary()
        let inputIDs = input.filter { $0.number == nil }.map { vocabulary.register($0.text) }
        let mustIDs = expectation.outsideWords.map { vocabulary.register($0.text) }
        let outputWordTokens = output.filter { $0.number == nil }
        let outputIDs = outputWordTokens.map { vocabulary.register($0.text) }
        let inputClasses = vocabulary.canonical(inputIDs)
        let mustClasses = vocabulary.canonical(mustIDs)
        let outputClasses = vocabulary.canonical(outputIDs)
        let matchedAll = Self.longestCommonSubsequence(outputClasses, inputClasses)
        let matchedMust = Self.longestCommonSubsequence(outputClasses, mustClasses)

        // Numbers are compared by value, so "twenty five" meets "25".
        let inputNumbers = input.reduce(into: Set<String>()) { $0.formUnion($1.number?.all ?? []) }
        let outputNumbers = output.reduce(into: Set<String>()) { $0.formUnion($1.number?.all ?? []) }
        let outputRuns = output.filter { $0.number != nil }
        let unsupportedRuns = outputRuns.filter { $0.number!.readings.isDisjoint(with: inputNumbers) }.count
        let droppedRuns = expectation.outsideNumbers.filter { $0.readings.isDisjoint(with: outputNumbers) }.count

        let added = (outputClasses.count - matchedAll) + unsupportedRuns
        let outputCount = outputClasses.count + outputRuns.count
        let expectedCount = expectation.allWords.count + expectation.allNumbers.count
        let outsideCount = expectation.outsideWords.count + expectation.outsideNumbers.count
        let dropped = (expectation.outsideWords.count - matchedMust) + droppedRuns
        let ratio = Double(outputCount) / Double(max(1, expectedCount))

        var failure: Failure?
        if Self.negationsChanged(expectation: expectation, output: output) {
            failure = .negationChanged
        } else if Self.identifiersChanged(raw: raw, cleaned: cleaned) {
            failure = .identifierChanged
        } else if Self.addsFormatting(raw: raw, cleaned: cleaned) {
            failure = .formatChanged
        } else if droppedRuns > 0 || unsupportedRuns > 0 {
            failure = .numberChanged
        } else if dropped > allowedDrops(expected: expectedCount, outside: outsideCount)
            || (input.contains { $0.inRegion } && expectedCount >= 1 && ratio < minRatio(forInputWords: expectedCount))
        {
            failure = .tooShort
        } else if expectedCount >= 4 && ratio > maxLengthRatio {
            failure = .tooLong
        } else if added > min(Int(Double(outputCount) * addedWordFraction), maxAddedWords) {
            failure = .addedContent
        }
        return Verdict(failure: failure, lengthRatio: ratio, addedWords: added)
    }

    /// Words a faithful edit may lose: none from a short input, a quarter of a longer one. Words inside a
    /// correction ("send it to Maria no wait") do not count; they are the speaker's retracted draft.
    func allowedDrops(expected: Int, outside: Int) -> Int {
        expected <= strictInputWords ? 0 : Int(Double(outside) * (1 - plainMinRatio))
    }

    /// Ramps from the short-input floor at 12 words to the long-input floor at 30 words.
    func minRatio(forInputWords count: Int) -> Double {
        if count <= 12 { return shortInputMinRatio }
        if count >= 30 { return longInputMinRatio }
        let t = Double(count - 12) / 18
        return shortInputMinRatio + t * (longInputMinRatio - shortInputMinRatio)
    }

    // MARK: - Tokens

    /// One word of a dictation, with what the guard needs to know about where it sits.
    struct Token: Equatable, Sendable {
        var text: String
        var afterComma = false
        var capitalized = false
        var startsSentence = false
        /// Which kind of negation this word is, if any: "not" for not, n't and cannot; "no", "never", "nothing"...
        var negation: String?
        /// um, uh, a stutter fragment, or a discourse "you know" / "like" that sits between commas.
        var isFiller = false
        /// Set on a number run, which stands for all of its words ("twenty five" or "3:30"); `text` is "#".
        var number: SpokenNumber?
        /// Part of a spoken correction: the draft the speaker retracted and the words that retract it.
        var inRegion = false
    }

    static let fillers: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "er", "erm", "hm", "hmm", "mhm", "ah", "ahh"]

    /// Words in the order spoken: hyphens split, apostrophes dropped ("it's" meets "its"), and stutter
    /// fragments ("w-we", "th- the") marked as fillers.
    static func lex(_ text: String) -> [Token] {
        let words = WER.words(text, numberAware: true)
        var tokens: [Token] = []
        tokens.reserveCapacity(words.count)
        var carried = Token(text: "")
        for (index, word) in words.enumerated() {
            let pieces = word.text.split(separator: "-", omittingEmptySubsequences: true)
                .map { String($0.filter { $0 != "'" }) }
                .filter { !$0.isEmpty }
            for (position, piece) in pieces.enumerated() {
                var token = Token(text: piece)
                if position == 0 {
                    token.afterComma = word.afterComma
                    token.capitalized = word.capitalized
                    token.startsSentence = word.startsSentence
                    if pieces.count == 1 { token.negation = negationClass(word.text) }
                }
                token.afterComma = token.afterComma || carried.afterComma
                token.capitalized = token.capitalized || carried.capitalized
                token.startsSentence = token.startsSentence || carried.startsSentence
                let next: String? =
                    position + 1 < pieces.count
                    ? pieces[position + 1]
                    : (word.hyphenAfter && index + 1 < words.count ? words[index + 1].text.split(separator: "-").first.map(String.init) : nil)
                if let next, isStutterFragment(piece, before: next) {
                    // "w-we" and "th- the": the fragment is not a word, and the word after it takes its place.
                    carried = token
                    continue
                }
                carried = Token(text: "")
                tokens.append(token)
            }
        }
        return tokens
    }

    private static func isStutterFragment(_ piece: String, before next: String) -> Bool {
        piece.count <= 4 && next.count > piece.count && next.hasPrefix(piece) && piece.allSatisfy(\.isLetter)
    }

    /// Lexed, with fillers marked and number runs collapsed. The output of a cleaner needs nothing more.
    static func prepare(_ text: String) -> [Token] {
        collapsingNumbers(markingFillers(lex(text)))
    }

    /// The input of a cleaner, ready to compare with `output`: split words rejoined to match its spelling
    /// ("p m" meets "pm"), fillers and numbers marked, and the spoken corrections found.
    /// `before` and `after` are the dictation around the text when it is one chunk of a longer one.
    static func analyze(
        _ text: String, matching outputWords: Set<String>, before: String = "", after: String = "", strictFillers: Bool = false
    ) -> [Token] {
        let main = collapsingNumbers(markingFillers(joinSplitWords(lex(text), matching: outputWords), strict: strictFillers))
        func context(_ text: String) -> [Token] { text.isEmpty ? [] : prepare(text) }
        let leading = Array(context(before).suffix(contextWords))
        let trailing = Array(context(after).prefix(contextWords))
        var combined = leading + main + trailing
        markCorrections(&combined)
        return Array(combined[leading.count..<(leading.count + main.count)])
    }

    /// How many words either side of a chunk are read to recognise a correction.
    static let contextWords = 24

    // MARK: - Fillers

    private static let discourseOpeners: Set<String> = ["so", "and", "but", "well", "okay", "ok", "yeah", "right", "then", "now", "anyway"]
    /// After "you know" these make it a verb ("you know the answer"), not a filler.
    private static let youKnowObjects: Set<String> = [
        "the", "a", "an", "that", "what", "how", "where", "when", "why", "who", "which", "if", "whether", "him", "them", "me", "us",
        "my", "your", "his", "her", "their", "our",
    ]
    /// Before "you know" these make it a verb ("do you know", "as you know").
    private static let youKnowLeaders: Set<String> = [
        "do", "does", "did", "dont", "doesnt", "didnt", "would", "could", "can", "cant", "will", "wont", "wouldnt", "couldnt", "if",
        "as", "what", "how", "who", "where", "when", "why", "whether", "that", "i", "we", "they",
    ]

    /// Marks um/uh, and the "you know" and "like" a speaker drops between commas. A bare "you know" or "like"
    /// is ordinary language ("do you know the answer", "I like it") and must survive.
    /// `strict` marks nothing beyond that: the guard also lets "so you know we need time" lose its "you know",
    /// since the model has no commas to go by, but a loss report should not.
    static func markingFillers(_ tokens: [Token], strict: Bool = false) -> [Token] {
        var result = tokens
        func endsClause(at next: Int) -> Bool {
            next >= tokens.count || tokens[next].afterComma || tokens[next].startsSentence
        }
        for i in tokens.indices {
            let text = tokens[i].text
            if fillers.contains(text) {
                result[i].isFiller = true
            } else if text == "like", tokens[i].afterComma, endsClause(at: i + 1) || (!strict && i > 0 && result[i - 1].isFiller) {
                // ", like," and "you know, like": the comma before it marks it as speech filler.
                result[i].isFiller = true
            } else if text == "you", i + 1 < tokens.count, tokens[i + 1].text == "know" {
                let leader = i > 0 ? tokens[i - 1].text : nil
                let follower = i + 2 < tokens.count ? tokens[i + 2].text : nil
                let commaBounded = tokens[i].afterComma && endsClause(at: i + 2)
                let afterOpener = leader.map(discourseOpeners.contains) == true && follower.map(youKnowObjects.contains) != true
                let sentenceFinal = endsClause(at: i + 2) && leader.map(youKnowLeaders.contains) != true
                if commaBounded || (!strict && (afterOpener || sentenceFinal)) {
                    result[i].isFiller = true
                    result[i + 1].isFiller = true
                }
            }
        }
        return result
    }

    // MARK: - Numbers

    /// Replaces each run of number words and digit groups with one token, so "twenty five" and "25" count as
    /// one word each and a number can be compared by value.
    static func collapsingNumbers(_ tokens: [Token]) -> [Token] {
        guard tokens.contains(where: { isNumberCandidate($0.text) }) else { return tokens }
        let texts = tokens.map { $0.isFiller ? "" : $0.text }
        let breaks = tokens.indices.map { $0 == 0 || tokens[$0].afterComma || tokens[$0].startsSentence }
        let runs = SpokenNumber.runs(in: texts, breaksBefore: breaks)
        var result: [Token] = []
        result.reserveCapacity(tokens.count)
        var next = 0
        for run in runs {
            result.append(contentsOf: tokens[next..<run.range.lowerBound])
            var token = tokens[run.range.lowerBound]
            token.text = "#"
            token.number = run.number
            token.negation = nil
            result.append(token)
            next = run.range.upperBound
        }
        result.append(contentsOf: tokens[next...])
        return result
    }

    private static func isNumberCandidate(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        if first.value >= 48 && first.value <= 57 { return true }
        return SpokenNumber.units[word] != nil || SpokenNumber.teens[word] != nil || SpokenNumber.tens[word] != nil
            || SpokenNumber.scales[word] != nil || SpokenNumber.ordinals[word] != nil || word == "first" || word == "second" || word == "a"
    }

    // MARK: - Negation

    private static let negationWords: [String: String] = [
        "not": "not", "cannot": "not", "no": "no", "never": "never", "nothing": "nothing", "none": "none", "nobody": "nobody",
        "nowhere": "nowhere", "neither": "neither", "nor": "nor", "without": "without",
    ]
    /// The same, spelled without the apostrophe, which some transcripts do.
    private static let bareContractions: Set<String> = [
        "cant", "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent", "hasnt", "havent", "hadnt", "couldnt", "wouldnt",
        "shouldnt", "wont", "mustnt", "neednt", "aint", "shant", "mightnt",
    ]

    /// The kind of negation a word carries, from its spelling with apostrophes: "can't", "not" and "cannot"
    /// are all "not"; dropping any of them, or turning one into another kind, flips the meaning.
    static func negationClass(_ word: String) -> String? {
        if let kind = negationWords[word] { return kind }
        if word.hasSuffix("n't") || bareContractions.contains(word) { return "not" }
        return nil
    }

    /// Negations the dictation has and the output lacks (or the reverse). Negations inside a correction
    /// may go, as the correction retracts them; all others must come back, no more and no fewer.
    static func negationsChanged(expectation: Expectation, output: [Token]) -> Bool {
        func counts(_ tokens: [Token]) -> [String: Int] {
            var result: [String: Int] = [:]
            for token in tokens { if let kind = token.negation { result[kind, default: 0] += 1 } }
            return result
        }
        let upper = counts(expectation.allWords)
        let lower = counts(expectation.outsideWords)
        let actual = counts(collapsingRepeats(output.filter { $0.number == nil }))
        for kind in Set(upper.keys).union(lower.keys).union(actual.keys) {
            let have = actual[kind, default: 0]
            if have < lower[kind, default: 0] || have > upper[kind, default: 0] { return true }
        }
        return false
    }

    // MARK: - What a faithful edit keeps

    struct Expectation {
        /// The words a plain edit keeps: no fillers, repeats collapsed, dictated punctuation gone.
        var allWords: [Token]
        /// The same, without the words inside a spoken correction.
        var outsideWords: [Token]
        var allNumbers: [SpokenNumber]
        var outsideNumbers: [SpokenNumber]
    }

    /// Dictated punctuation that becomes a symbol or a break, with the symbol that must then be in the output.
    static let spokenPunctuation: [(words: [String], symbol: Unicode.Scalar)] = [
        (["comma"], ","), (["period"], "."), (["full", "stop"], "."), (["question", "mark"], "?"), (["exclamation", "point"], "!"),
        (["exclamation", "mark"], "!"), (["new", "line"], "\n"), (["new", "paragraph"], "\n"),
    ]

    static func expectation(from input: [Token], cleaned: String) -> Expectation {
        var words = input.filter { !$0.isFiller && $0.number == nil }
        let symbols = Set(cleaned.unicodeScalars)
        for (phrase, symbol) in spokenPunctuation where symbols.contains(symbol) {
            words = removing(phrase, from: words)
        }
        words = collapsingRepeats(words)
        let numbers = input.filter { !$0.isFiller && $0.number != nil }
        return Expectation(
            allWords: words, outsideWords: words.filter { !$0.inRegion }, allNumbers: numbers.map { $0.number! },
            outsideNumbers: numbers.filter { !$0.inRegion }.map { $0.number! })
    }

    /// Drops immediately repeated runs of one to three words ("we should we should" becomes "we should").
    static func collapsingRepeats(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            result.append(token)
            for length in [3, 2, 1] where result.count >= 2 * length {
                let end = result.count
                var repeated = true
                for offset in 1...length where result[end - offset].text != result[end - length - offset].text {
                    repeated = false
                    break
                }
                if repeated {
                    // Keep the first copy's flags, the repeat's inRegion mark is irrelevant once it is gone.
                    result.removeLast(length)
                    break
                }
            }
        }
        return result
    }

    static func removing(_ phrase: [String], from tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < tokens.count {
            if i + phrase.count <= tokens.count, phrase.indices.allSatisfy({ tokens[i + $0].text == phrase[$0] }) {
                i += phrase.count
            } else {
                result.append(tokens[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - Spoken corrections

    /// Wording that explains why a faithful edit may drop a clause. By itself it explains nothing:
    /// "please wait for the build" and "we should actually move it" are plain sentences.
    static let correctionCues: [[String]] = [
        ["scratch", "that"], ["strike", "that"], ["never", "mind"], ["nevermind"], ["make", "that"], ["i", "mean"],
        ["or", "rather"], ["wait"], ["actually"], ["sorry"], ["oops"], ["correction"],
    ]

    private static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "by", "and", "or", "but", "so", "if", "is", "are",
        "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those", "i", "you", "he", "she", "we", "they",
        "me", "him", "her", "us", "them", "my", "your", "his", "our", "their", "do", "does", "did", "can", "could", "will", "would",
        "should", "shall", "may", "might", "must", "have", "has", "had", "not", "no", "as", "than", "then", "there", "here", "up",
        "out", "just", "also", "very", "too", "im", "ive", "id", "ill", "lets", "thats", "its", "dont", "cant", "wont",
    ]
    private static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// How far back the retracted draft may begin, and how far into the replacement an echo is looked for.
    private static let draftWords = 12
    private static let replacementWords = 6

    /// Marks the words of each spoken correction: the cue ("no wait", "scratch that", "I mean"), and the draft
    /// it retracts. A cue only counts when the words after it repeat or replace something just before it:
    /// the same phrase again, or a number, weekday, month or name swapped for another. Lone cue words in
    /// ordinary sentences ("please wait for the build") retract nothing, so they excuse nothing.
    static func markCorrections(_ tokens: inout [Token]) {
        let core = tokens.indices.filter { !tokens[$0].isFiller }
        guard core.count >= 3 else { return }
        var isCue = [Bool](repeating: false, count: core.count)
        for k in core.indices {
            for phrase in correctionCues where k + phrase.count <= core.count {
                if phrase.indices.allSatisfy({ tokens[core[k + $0]].text == phrase[$0] }) {
                    for offset in phrase.indices { isCue[k + offset] = true }
                }
            }
        }
        // A "no" after a comma retracts what came before: "on Tuesday, no, Wednesday". Next to another cue it is
        // part of it ("no wait"), and between two echoing words it needs no comma ("Tuesday no Wednesday").
        let phraseCue = isCue
        for k in core.indices where tokens[core[k]].text == "no" {
            let nextToCue = (k > 0 && phraseCue[k - 1]) || (k + 1 < core.count && phraseCue[k + 1])
            let betweenEchoes = k > 0 && k + 1 < core.count && echoes(tokens[core[k - 1]], tokens[core[k + 1]])
            if tokens[core[k]].afterComma || nextToCue || betweenEchoes { isCue[k] = true }
        }

        var k = 0
        while k < core.count {
            guard isCue[k] else {
                k += 1
                continue
            }
            var end = k
            while end < core.count, isCue[end] { end += 1 }
            if let start = draftStart(core: core, tokens: tokens, cue: k..<end) {
                for position in start..<end { tokens[core[position]].inRegion = true }
            }
            k = end
        }
    }

    /// Where the retracted draft begins, if what follows the cue echoes it.
    private static func draftStart(core: [Int], tokens: [Token], cue: Range<Int>) -> Int? {
        guard cue.lowerBound > 0 else { return nil }
        let limit = min(core.count, cue.upperBound + replacementWords)
        for after in cue.upperBound..<limit {
            let offset = after - cue.upperBound
            let candidate = tokens[core[after]]
            for before in stride(from: cue.lowerBound - 1, through: max(0, cue.lowerBound - draftWords), by: -1)
            where echoes(tokens[core[before]], candidate) {
                return max(0, before - offset)
            }
        }
        return nil
    }

    private static func echoes(_ earlier: Token, _ later: Token) -> Bool {
        if earlier.number != nil || later.number != nil { return earlier.number != nil && later.number != nil }
        if earlier.text == later.text { return !functionWords.contains(later.text) && later.text.count > 1 }
        if weekdays.contains(earlier.text) && weekdays.contains(later.text) { return true }
        if SpokenNumber.months.contains(earlier.text) && SpokenNumber.months.contains(later.text) { return true }
        // Two names: "send it to Maria, no, Marcus".
        return earlier.capitalized && later.capitalized && !earlier.startsSentence && !later.startsSentence && earlier.text != "i"
            && later.text != "i"
    }

    // MARK: - Matching

    /// Merges runs of 2 or 3 input words into one when the output has the joined spelling,
    /// so "p m" meets "pm", "use auth session" meets "useauthsession" and "do not" meets "don't".
    static func joinSplitWords(_ input: [Token], matching outputWords: Set<String>) -> [Token] {
        var result: [Token] = []
        result.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            var merged = false
            for length in [3, 2] where i + length <= input.count {
                let run = input[i..<(i + length)]
                let texts = run.map(\.text)
                var candidates = [texts.joined()]
                if texts.last == "not" {
                    // "do not" meets "don't", "will not" meets "won't".
                    candidates.append(texts.dropLast().joined() + "nt")
                    if texts.dropLast() == ["will"] { candidates.append("wont") }
                }
                if let candidate = candidates.first(where: outputWords.contains), !run.contains(where: { outputWords.contains($0.text) }) {
                    var token = input[i]
                    token.text = candidate
                    token.negation = run.compactMap(\.negation).first
                    result.append(token)
                    i += length
                    merged = true
                    break
                }
            }
            if !merged {
                result.append(input[i])
                i += 1
            }
        }
        return result
    }

    static func joinSplitWords(_ input: [String], matching outputWords: Set<String>) -> [String] {
        joinSplitWords(input.map { Token(text: $0) }, matching: outputWords).map(\.text)
    }

    /// Length of the longest common subsequence of `output` within `input`, with inflections counted as equal.
    static func orderedMatches(_ output: [String], _ input: [String]) -> Int {
        var vocabulary = Vocabulary()
        let outputIDs = output.map { vocabulary.register($0) }
        let inputIDs = input.map { vocabulary.register($0) }
        return longestCommonSubsequence(vocabulary.canonical(outputIDs), vocabulary.canonical(inputIDs))
    }

    /// Same word, allowing genuine inflection only: plural or -s/-es/-ed/-ing ("session" and "sessions",
    /// "ship" and "shipped"). Not an arbitrary longer word with the same start: "can" and "can't",
    /// "not" and "note" differ in meaning.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aBases = Vocabulary.bases(of: a)
        return Vocabulary.bases(of: b).contains(where: aBases.contains)
    }

    /// Words as numbers, with inflections of one word sharing a number.
    struct Vocabulary {
        private var ids: [String: Int] = [:]
        private var parent: [Int] = []
        private var owners: [String: Int] = [:]

        mutating func register(_ word: String) -> Int {
            if let id = ids[word] { return id }
            let id = parent.count
            parent.append(id)
            ids[word] = id
            for base in Self.bases(of: word) {
                if let owner = owners[base] { union(id, owner) } else { owners[base] = id }
            }
            return id
        }

        /// The ids of each word's group, once all words are registered.
        mutating func canonical(_ ids: [Int]) -> [Int] { ids.map { find($0) } }

        private mutating func find(_ id: Int) -> Int {
            var root = id
            while parent[root] != root { root = parent[root] }
            var node = id
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        private mutating func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        /// The word, and the words it may be an inflection of ("shipped" -> "ship"). Two words are the same
        /// when they share one.
        static func bases(of word: String) -> [String] {
            var result = [word]
            guard word.count >= 4, word.allSatisfy(\.isLetter) else { return result }
            func stem(_ dropping: Int, adding: String = "") -> String? {
                let stem = String(word.dropLast(dropping)) + adding
                return stem.count >= 3 ? stem : nil
            }
            func undoubled(_ stem: String?) -> String? {
                guard let stem, let last = stem.last, stem.count >= 4, !"aeiou".contains(last),
                    stem[stem.index(before: stem.endIndex)] == stem[stem.index(stem.endIndex, offsetBy: -2)]
                else { return nil }
                return String(stem.dropLast())
            }
            var candidates: [String?] = []
            if word.hasSuffix("ies") || word.hasSuffix("ied") { candidates.append(stem(3, adding: "y")) }
            if word.hasSuffix("es") { candidates.append(stem(2)) }
            if word.hasSuffix("s") { candidates.append(stem(1)) }
            if word.hasSuffix("ed") {
                candidates += [stem(2), stem(1), undoubled(stem(2))]
            }
            if word.hasSuffix("ing") {
                candidates += [stem(3), stem(3, adding: "e"), undoubled(stem(3))]
            }
            for case let candidate? in candidates where !result.contains(candidate) { result.append(candidate) }
            return result
        }
    }

    /// Length of the longest common subsequence, found by growing the number of edits until the ends meet.
    /// Edits are few when the output is an edit of the input, so this is close to linear; for texts that
    /// share little it stops early with an upper bound, as the verdict is then a rejection anyway.
    static func longestCommonSubsequence(_ a: [Int], _ b: [Int]) -> Int {
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        let common = start + (a.count - endA)
        let n = endA - start
        let m = endB - start
        if n == 0 || m == 0 { return common }

        let maxEdits = min(n + m, max(1024, (n + m) / 4))
        let offset = maxEdits + 1
        var furthest = [Int](repeating: 0, count: 2 * maxEdits + 3)
        return a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for edits in 0...maxEdits {
                    var diagonal = -edits
                    while diagonal <= edits {
                        var x: Int
                        if diagonal == -edits || (diagonal != edits && furthest[offset + diagonal - 1] < furthest[offset + diagonal + 1]) {
                            x = furthest[offset + diagonal + 1]
                        } else {
                            x = furthest[offset + diagonal - 1] + 1
                        }
                        var y = x - diagonal
                        while x < n, y < m, a[start + x] == b[start + y] {
                            x += 1
                            y += 1
                        }
                        furthest[offset + diagonal] = x
                        if x >= n, y >= m { return common + (n + m - edits) / 2 }
                        diagonal += 2
                    }
                }
                return common + max(0, (n + m - maxEdits - 1) / 2)
            }
        }
    }

    // MARK: - Identifiers and formatting

    /// An identifier in the dictation (camelCase, snake_case, S3) must come back exactly as written.
    static func identifiersChanged(raw: String, cleaned: String) -> Bool {
        Preservation.identifiers(in: raw).contains { !cleaned.contains($0) }
    }

    /// True when the output has list markers, markdown, emoji, or a question or exclamation mark that the
    /// dictation did not have: formatting is the cleaner's invention, not the speaker's.
    static func addsFormatting(raw: String, cleaned: String) -> Bool {
        if lineMarkers(in: cleaned) > lineMarkers(in: raw) { return true }
        for marker in ["**", "`", "~~", "]("] where count(of: marker, in: cleaned) > count(of: marker, in: raw) { return true }
        if emojiCount(in: cleaned) > emojiCount(in: raw) { return true }
        return addsTerminalMark(raw: raw, cleaned: cleaned)
    }

    /// Lines that start with a bullet, a number, or a heading mark.
    static func lineMarkers(in text: String) -> Int {
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first else { continue }
            let rest = trimmed.dropFirst()
            if "-*\u{2022}>".contains(first), rest.first == " " {
                count += 1
            } else if first == "#", rest.drop(while: { $0 == "#" }).first == " " {
                count += 1
            } else if first.isNumber {
                let afterDigits = trimmed.drop(while: \.isNumber)
                if let mark = afterDigits.first, ".)".contains(mark), afterDigits.dropFirst().first == " " { count += 1 }
            }
        }
        return count
    }

    private static func count(of marker: String, in text: String) -> Int {
        guard !marker.isEmpty else { return 0 }
        return text.components(separatedBy: marker).count - 1
    }

    static func emojiCount(in text: String) -> Int {
        text.unicodeScalars.filter { $0.value > 0x2000 && ($0.properties.isEmojiPresentation || $0.properties.isEmoji) }.count
    }

    /// Words that open a question, so "Are you done?" needs no question mark in the dictation.
    private static let questionOpeners: Set<String> = [
        "who", "whom", "whose", "what", "when", "where", "why", "how", "which", "is", "are", "was", "were", "am", "do", "does",
        "did", "can", "could", "will", "would", "should", "shall", "may", "might", "must", "have", "has", "had", "isnt", "arent",
        "wasnt", "werent", "dont", "doesnt", "didnt", "cant", "couldnt", "wont", "wouldnt", "shouldnt", "havent", "hasnt", "hadnt",
    ]

    /// "We are done" must not become "We are done?": a question mark is allowed where the sentence opens like a
    /// question, where the speaker said "question mark", or where the dictation already had one. Likewise "!".
    static func addsTerminalMark(raw: String, cleaned: String) -> Bool {
        guard cleaned.contains("?") || cleaned.contains("!") else { return false }
        let spoken = lex(raw).map(\.text)
        let spokenQuestionMarks = spoken.indices.filter { spoken[$0] == "question" && $0 + 1 < spoken.count && spoken[$0 + 1] == "mark" }
        let questionsSaid = count(of: "?", in: raw) + spokenQuestionMarks.count
        let bangsSaid = count(of: "!", in: raw) + spoken.indices.filter { spoken[$0] == "exclamation" }.count

        var natural = 0
        var invented = 0
        var sentence = ""
        for character in cleaned {
            if character == "?" {
                if opensAQuestion(lex(sentence)) { natural += 1 } else { invented += 1 }
                sentence = ""
            } else if ".!\n".contains(character) {
                sentence = ""
            } else {
                sentence.append(character)
            }
        }
        if invented > max(0, questionsSaid - natural) { return true }
        return count(of: "!", in: cleaned) > bangsSaid
    }

    /// Words that lead into a question without being part of it: "Okay, what time is it?", "Hey Sam, are you free?".
    private static let questionLeaders: Set<String> = [
        "so", "and", "but", "well", "okay", "ok", "yeah", "then", "now", "anyway", "right", "hey", "hi", "hello", "please",
    ]

    /// A sentence opens like a question when its first word, the first after a leading "so" or "okay", or the
    /// first of any comma-separated clause is a question word or an auxiliary verb.
    private static func opensAQuestion(_ sentence: [Token]) -> Bool {
        guard let first = sentence.firstIndex(where: { !$0.isFiller && !questionLeaders.contains($0.text) }) else { return false }
        if questionOpeners.contains(sentence[first].text) { return true }
        return sentence.contains { $0.afterComma && questionOpeners.contains($0.text) }
    }

    // MARK: - Chat framing

    /// Openers and closers a model adds when it talks to the user instead of editing.
    /// Ignored when the speaker actually said them.
    static let openers = [
        "sure", "certainly", "of course", "absolutely", "here is", "here's", "here are", "okay here", "ok here",
        "i'm sorry", "i am sorry", "sorry but", "i apologize", "i can't", "i cannot", "i'm unable", "i am unable",
        "as an ai", "unfortunately", "the cleaned", "cleaned", "edited", "corrected", "output", "transcript", "note",
    ]
    static let closers = [
        "let me know if", "i hope this helps", "hope this helps", "feel free to", "is there anything else",
    ]

    /// `input` should already have its um/uh fillers removed, so "um sure that works" may become "Sure, that works".
    static func hasChattyFraming(input: [String], output: [String]) -> Bool {
        for phrase in openers {
            let words = lex(phrase).map(\.text)
            if output.starts(with: words) && !input.starts(with: words) { return true }
        }
        for phrase in closers {
            let words = lex(phrase).map(\.text)
            if contains(output, words) && !contains(input, words) { return true }
        }
        return false
    }

    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
