import Foundation

/// Decides whether an AI cleaner's output can be trusted as an edit of its input.
///
/// The dictation is untrusted text that an AI model edits, so the model may answer it, obey it, or simply
/// damage it. A tolerance ("a few extra words are fine") can always be exploited, so this is a whitelist:
/// the output is trusted only if it is the input with nothing but these edits applied.
///
///  - a filler removed (um, uh, a comma-bounded "you know" or "like"),
///  - one copy of an immediately repeated word or phrase removed (a stutter),
///  - a retracted draft removed, with or without the cue that retracts it ("no wait", "scratch that"): the
///    clause directly before the cue, and only when what follows the cue re-says or replaces it,
///  - a dictated "comma", "period", "new paragraph" removed where the output has that symbol or break,
///  - a spoken number written as digits with the same value and in the same order ("three thirty" is 3:30),
///  - case, punctuation, whitespace and paragraph breaks changed, with a final "?" added only to a sentence
///    that plainly asks,
///  - a word joined, split or hyphenated without changing its letters.
///
/// Anything else rejects: an added word, a changed word, a dropped word outside a retraction, reordered words,
/// ALL CAPS or lost capitals on names, markdown or symbols the speaker never dictated, a changed identifier.
/// Callers then use the deterministic rules output instead.
public struct CleanupGuard: Sendable {
    public enum Failure: Sendable, Equatable {
        /// Nothing came back although the input had words to keep.
        case emptyOutput
        /// Far more words than the input: added content or duplicated text.
        case tooLong
        /// Starts or ends like a chat reply ("Sure, here is...", "I'm sorry...").
        case chattyFraming
        /// A "not", "never", "no" or n't form was dropped, added or swapped.
        case negationChanged
        /// A number in the dictation has another value in the output, or the output has a number nobody said.
        case numberChanged
        /// An identifier (camelCase, snake_case, S3) changed spelling or case.
        case identifierChanged
        /// List markers, markdown, emoji, symbols, or a question or exclamation mark the speaker never dictated.
        case formatChanged
        /// ALL CAPS, Title Case, or a name or acronym that lost its capitals.
        case caseChanged
        /// Words the speaker never said: an answer, a preface, a sign-off.
        case wordAdded
        /// A word replaced by another, or words in another order.
        case wordChanged
        /// Words the speaker said are missing and no filler, stutter or retraction accounts for them.
        case contentDropped
        /// The text differs from the dictation in a way none of the allowed edits explains.
        case unexplainedChange
    }

    public struct Verdict: Sendable, Equatable {
        public let failure: Failure?
        /// Output words (a number counts as one) divided by the input words a plain edit would keep.
        public let lengthRatio: Double
        /// Output words (a number counts as one) that the input does not have; only counted for a rejection.
        public let addedWords: Int

        public var isTrustworthy: Bool { failure == nil }
    }

    public init() {}

    public static let standard = CleanupGuard()

    public func isTrustworthy(raw: String, cleaned: String) -> Bool {
        evaluate(raw: raw, cleaned: cleaned).isTrustworthy
    }

    /// `raw` and `cleaned` are the whole dictation and its cleanup. `before` and `after` are the dictation around
    /// them when they are only a part of it: a retraction can begin in one part and end in the next ("send it to
    /// Maria no wait" / "send it to Marcus"). They are only used to recognise retractions, never to excuse the
    /// part's own words.
    public func evaluate(raw: String, cleaned: String, before: String = "", after: String = "") -> Verdict {
        let rawTokens = Self.lex(raw)
        let written = Self.lexed(cleaned)
        let inputVocabulary = Set(rawTokens.map(\.text))
        let input = Self.analyze(tokens: rawTokens, matching: Set(written.tokens.map(\.text)), before: before, after: after)
        let output = Self.collapsingNumbers(Self.joinSplitWords(written.tokens, matching: inputVocabulary))

        if output.isEmpty {
            return Verdict(failure: input.contains { !$0.isDeletable } ? .emptyOutput : nil, lengthRatio: 0, addedWords: 0)
        }
        if Self.hasChattyFraming(input: input.filter { !$0.isFiller }.map(\.text), output: output.map(\.text)) {
            return Verdict(failure: .chattyFraming, lengthRatio: 0, addedWords: 0)
        }

        let expectation = Self.expectation(from: input, cleaned: cleaned)
        let expected = expectation.allWords.count + expectation.allNumbers.count
        let ratio = Double(output.count) / Double(max(1, expected))
        func verdict(_ failure: Failure?, added: Int = 0) -> Verdict { Verdict(failure: failure, lengthRatio: ratio, addedWords: added) }

        if Self.identifiersChanged(raw: raw, cleaned: cleaned) { return verdict(.identifierChanged) }
        if Self.addsFormatting(raw: raw, cleaned: cleaned) { return verdict(.formatChanged) }
        if Self.changesCaseWholesale(raw: raw, cleaned: cleaned) { return verdict(.caseChanged) }
        if Double(output.count) > Self.maxLengthRatio * Double(input.count) + Double(Self.lengthSlack) {
            return verdict(.tooLong, added: output.count - input.count)
        }

        let aligner = Aligner(input: input, output: output, trailing: written.trailingMarks, shouting: Self.isShouting(raw))
        if aligner.isFeasible(enforcingCase: true) {
            return Self.looksTitleCased(input: input, output: output) ? verdict(.caseChanged) : verdict(nil)
        }
        if aligner.isFeasible(enforcingCase: false) { return verdict(.caseChanged) }
        let diagnosis = Self.diagnose(input: input, output: output, expectation: expectation)
        return verdict(diagnosis.failure, added: diagnosis.added)
    }

    /// A cheap sanity bound before aligning: joins and splits move the word count a little, never by half again.
    static let maxLengthRatio = 1.5
    static let lengthSlack = 4

    // MARK: - Tokens

    /// One word of a dictation, with what the guard needs to know about where it sits.
    struct Token: Equatable, Sendable {
        var text: String
        var afterComma = false
        var capitalized = false
        /// Two or more letters, all upper case ("NASA").
        var allCaps = false
        var startsSentence = false
        /// Punctuation and line breaks between the previous word and this one.
        var marksBefore: WER.Marks = []
        /// Which kind of negation this word is, if any: "not" for not, n't and cannot; "no", "never", "nothing"...
        var negation: String?
        /// um, uh, a stutter fragment, or a discourse "you know" / "like" that sits between commas.
        var isFiller = false
        /// Set on a number run, which stands for all of its words ("twenty five" or "3:30"); `text` is "#".
        var number: SpokenNumber?
        /// Part of a spoken correction: the draft the speaker retracted and the words that retract it.
        var inRegion = false
        /// The second and later copy of an immediately repeated word or phrase.
        var isRepeat = false

        /// May be left out of the output without changing what the speaker said.
        var isDeletable: Bool { isFiller || isRepeat || inRegion }
    }

    static let fillers: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "er", "erm", "hm", "hmm", "mhm", "ah", "ahh"]

    /// Words in the order spoken: hyphens split, apostrophes dropped ("it's" meets "its"), and stutter
    /// fragments ("w-we", "th- the") marked as fillers.
    static func lex(_ text: String) -> [Token] {
        lexed(text).tokens
    }

    /// `lex`, plus the punctuation after the last word.
    static func lexed(_ text: String) -> (tokens: [Token], trailingMarks: WER.Marks) {
        let result = WER.lexed(text, numberAware: true)
        let words = splittingSuffixes(result.words)
        var tokens: [Token] = []
        tokens.reserveCapacity(words.count)
        var carried = Token(text: "")
        for (index, word) in words.enumerated() {
            let pieces: [String]
            if word.text.utf8.contains(where: { $0 == 45 || $0 == 39 }) {
                pieces = word.text.split(separator: "-", omittingEmptySubsequences: true)
                    .map { String($0.filter { $0 != "'" }) }
                    .filter { !$0.isEmpty }
            } else {
                pieces = [word.text]
            }
            for (position, piece) in pieces.enumerated() {
                var token = Token(text: piece)
                token.allCaps = word.allCaps
                if position == 0 {
                    token.afterComma = word.afterComma
                    token.capitalized = word.capitalized
                    token.startsSentence = word.startsSentence
                    token.marksBefore = word.marksBefore
                    if pieces.count == 1 { token.negation = negationClass(word.text) }
                }
                token.afterComma = token.afterComma || carried.afterComma
                token.capitalized = token.capitalized || carried.capitalized
                token.startsSentence = token.startsSentence || carried.startsSentence
                token.marksBefore.formUnion(carried.marksBefore)
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
        return (tokens, result.trailingMarks)
    }

    private static func isStutterFragment(_ piece: String, before next: String) -> Bool {
        piece.count <= 4 && next.count > piece.count && next.hasPrefix(piece) && piece.allSatisfy(\.isLetter)
    }

    /// Spoken units and the abbreviations a number is written with: "two point five gigabytes" is "2.5 GB".
    static let unitAbbreviations: [String: Set<String>] = [
        "gigabyte": ["gb"], "gigabytes": ["gb"], "megabyte": ["mb"], "megabytes": ["mb"], "kilobyte": ["kb"], "kilobytes": ["kb"],
        "terabyte": ["tb"], "terabytes": ["tb"], "kilometer": ["km"], "kilometers": ["km"], "kilometre": ["km"], "kilometres": ["km"],
        "kilogram": ["kg"], "kilograms": ["kg"], "millimeter": ["mm"], "millimeters": ["mm"], "centimeter": ["cm"],
        "centimeters": ["cm"], "millisecond": ["ms"], "milliseconds": ["ms"], "kilohertz": ["khz"], "megahertz": ["mhz"],
        "gigahertz": ["ghz"],
    ]
    private static let writtenUnits: Set<String> = Set(unitAbbreviations.values.flatMap { $0 }).union(["am", "pm"])
    private static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th"]

    /// "5th" is the number 5; "3pm" and "2.5GB" are a number and a word.
    private static func splittingSuffixes(_ words: [WER.Word]) -> [WER.Word] {
        guard words.contains(where: { $0.text.unicodeScalars.first.map { $0.value >= 48 && $0.value <= 57 } == true }) else { return words }
        var result: [WER.Word] = []
        result.reserveCapacity(words.count)
        for word in words {
            let scalars = Array(word.text.unicodeScalars)
            guard let first = scalars.first, first.value >= 48, first.value <= 57,
                let cut = scalars.firstIndex(where: { $0.properties.isAlphabetic }), cut > 0,
                scalars[cut - 1].value >= 48, scalars[cut - 1].value <= 57
            else {
                result.append(word)
                continue
            }
            let suffix = String(String.UnicodeScalarView(scalars[cut...]))
            guard ordinalSuffixes.contains(suffix) || writtenUnits.contains(suffix) else {
                result.append(word)
                continue
            }
            var number = word
            number.text = String(String.UnicodeScalarView(scalars[..<cut]))
            number.allCaps = false
            number.hyphenAfter = false
            result.append(number)
            if !ordinalSuffixes.contains(suffix) {
                result.append(WER.Word(text: suffix, allCaps: word.allCaps, hyphenAfter: word.hyphenAfter))
            }
        }
        return result
    }

    /// Lexed, with fillers marked and number runs collapsed. The output of a cleaner needs nothing more.
    static func prepare(_ text: String) -> [Token] {
        collapsingNumbers(markingFillers(lex(text)))
    }

    /// The input of a cleaner, ready to compare with `output`: split words rejoined to match its spelling
    /// ("p m" meets "pm"), fillers and numbers marked, and the repeats and spoken corrections found.
    /// `before` and `after` are the dictation around the text when it is one part of a longer one.
    static func analyze(
        _ text: String, matching outputWords: Set<String>, before: String = "", after: String = "", strictFillers: Bool = false
    ) -> [Token] {
        analyze(tokens: lex(text), matching: outputWords, before: before, after: after, strictFillers: strictFillers)
    }

    static func analyze(
        tokens lexedInput: [Token], matching outputWords: Set<String>, before: String = "", after: String = "",
        strictFillers: Bool = false
    ) -> [Token] {
        let main = collapsingNumbers(markingFillers(joinSplitWords(lexedInput, matching: outputWords), strict: strictFillers))
        func context(_ text: String) -> [Token] { text.isEmpty ? [] : prepare(text) }
        let leading = Array(context(before).suffix(contextWords))
        let trailing = Array(context(after).prefix(contextWords))
        var combined = leading + main + trailing
        markRepeats(&combined)
        markCorrections(&combined)
        return Array(combined[leading.count..<(leading.count + main.count)])
    }

    /// How many words either side of a part are read to recognise a correction.
    static let contextWords = 24

    // MARK: - Fillers

    private static let discourseOpeners: Set<String> = ["so", "and", "but", "well", "okay", "ok", "yeah", "right", "then", "now", "anyway"]
    /// After "you know" these make it a verb ("you know the answer"), not a filler.
    private static let youKnowObjects: Set<String> = [
        "the", "a", "an", "that", "what", "how", "where", "when", "why", "who", "which", "if", "whether", "him", "them", "me", "us",
        "my", "your", "his", "her", "their", "our",
    ]

    /// Marks um/uh, and the "you know" and "like" a speaker drops between commas. A bare "you know" or "like"
    /// is ordinary language ("do you know the answer", "I like it", "I think you know") and must survive.
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
            } else if text == "mm" || text == "mmm" {
                // "5 mm" is millimetres.
                if i == 0 || !isNumberCandidate(tokens[i - 1].text) { result[i].isFiller = true }
            } else if text == "like", tokens[i].afterComma, endsClause(at: i + 1) || (!strict && i > 0 && result[i - 1].isFiller) {
                // ", like," and "you know, like": the comma before it marks it as speech filler.
                result[i].isFiller = true
            } else if text == "you", i + 1 < tokens.count, tokens[i + 1].text == "know" {
                let leader = i > 0 ? tokens[i - 1].text : nil
                let follower = i + 2 < tokens.count ? tokens[i + 2].text : nil
                let commaBounded = tokens[i].afterComma && endsClause(at: i + 2)
                let afterOpener = leader.map(discourseOpeners.contains) == true && follower.map(youKnowObjects.contains) != true
                if commaBounded || (!strict && afterOpener) {
                    result[i].isFiller = true
                    result[i + 1].isFiller = true
                }
            }
        }
        return result
    }

    // MARK: - Repeats

    /// Flags the second and later copy of each immediately repeated run of one to three words ("we should we
    /// should call" keeps its first "we should"), looking past fillers. The first copy always stays.
    static func markRepeats(_ tokens: inout [Token]) {
        var kept: [Int] = []
        kept.reserveCapacity(tokens.count)
        for index in tokens.indices where !tokens[index].isFiller {
            kept.append(index)
            for length in [3, 2, 1] where kept.count >= 2 * length {
                let end = kept.count
                var repeated = true
                for offset in 1...length {
                    let later = tokens[kept[end - offset]]
                    let earlier = tokens[kept[end - length - offset]]
                    if later.number != nil || earlier.number != nil || later.text != earlier.text {
                        repeated = false
                        break
                    }
                }
                if repeated {
                    for position in (end - length)..<end { tokens[kept[position]].isRepeat = true }
                    kept.removeLast(length)
                    break
                }
            }
        }
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
            token.allCaps = false
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

    private static func marks(for symbol: Unicode.Scalar) -> WER.Marks {
        switch symbol {
        case ",": .comma
        case ".": .period
        case "?": .question
        case "!": .exclamation
        default: .newline
        }
    }

    static func expectation(from input: [Token], cleaned: String) -> Expectation {
        var words = input.filter { !$0.isFiller && !$0.isRepeat && $0.number == nil }
        let symbols = Set(cleaned.unicodeScalars)
        for (phrase, symbol) in spokenPunctuation where symbols.contains(symbol) {
            words = removing(phrase, from: words)
        }
        let numbers = input.filter { !$0.isFiller && !$0.isRepeat && $0.number != nil }
        return Expectation(
            allWords: words, outsideWords: words.filter { !$0.inRegion }, allNumbers: numbers.map { $0.number! },
            outsideNumbers: numbers.filter { !$0.inRegion }.map { $0.number! })
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

    /// Cues that take back what came before them wholesale. They need no echo: the speaker has cancelled the
    /// previous clause, with or without saying what replaces it, and at the very start they retract nothing.
    static let retractionCues: [[String]] = [["scratch", "that"], ["strike", "that"], ["never", "mind"], ["nevermind"]]
    /// Cues that only count when the words after them re-say or replace the words just before. By themselves
    /// they explain nothing: "please wait for the build" and "we should actually move it" are plain sentences.
    static let softCues: [[String]] = [
        ["actually", "make", "that"], ["make", "that"], ["no", "wait"], ["wait", "no"], ["i", "mean"], ["or", "rather"], ["sorry"],
        ["oops"], ["correction"], ["wait"], ["actually"], ["no"],
    ]
    private static let allCues: [(words: [String], retraction: Bool)] =
        (retractionCues.map { ($0, true) } + softCues.map { ($0, false) }).sorted { $0.words.count > $1.words.count }

    private static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "by", "and", "or", "but", "so", "if", "is", "are",
        "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those", "i", "you", "he", "she", "we", "they",
        "me", "him", "her", "us", "them", "my", "your", "his", "our", "their", "do", "does", "did", "can", "could", "will", "would",
        "should", "shall", "may", "might", "must", "have", "has", "had", "not", "no", "as", "than", "then", "there", "here", "up",
        "out", "just", "also", "very", "too", "im", "ive", "id", "ill", "lets", "thats", "dont", "cant", "wont", "isnt", "arent",
        "wasnt", "werent", "didnt", "doesnt", "couldnt", "wouldnt", "shouldnt", "havent", "hasnt", "hadnt",
    ]

    /// The most words a retraction takes back. Corrections re-say a few words; a longer stretch is content.
    private static let draftWords = 10

    /// Marks the words of each spoken correction as retractable: the cue ("no wait", "scratch that", "I mean"),
    /// and the draft it takes back, which is the clause directly before it. A draft counts only when what follows
    /// the cue re-says it with a change: same word or a swapped word of the same kind at each position, starting
    /// from its first word. A retraction cue ("scratch that") also takes back the whole clause when nothing
    /// follows to compare with.
    static func markCorrections(_ tokens: inout [Token]) {
        let core = tokens.indices.filter { !tokens[$0].isFiller && !tokens[$0].isRepeat }
        guard !core.isEmpty else { return }

        var position = 0
        while position < core.count {
            guard let first = cue(at: position, core: core, tokens: tokens) else {
                position += 1
                continue
            }
            // One group of back-to-back cues: "no wait scratch that".
            var end = position + first.length
            var retraction = first.retraction
            while end < core.count, let more = cue(at: end, core: core, tokens: tokens) {
                end += more.length
                retraction = retraction || more.retraction
            }
            let draft = draftLength(before: position, cueEnd: end, retraction: retraction, core: core, tokens: tokens)
            if let draft {
                for index in (position - draft)..<end { tokens[core[index]].inRegion = true }
            }
            position = end
        }
    }

    private static func cue(at position: Int, core: [Int], tokens: [Token]) -> (length: Int, retraction: Bool)? {
        for candidate in allCues where position + candidate.words.count <= core.count {
            if candidate.words.indices.allSatisfy({ tokens[core[position + $0]].text == candidate.words[$0] && tokens[core[position + $0]].number == nil }) {
                return (candidate.words.count, candidate.retraction)
            }
        }
        return nil
    }

    /// How many words before the cue group are the retracted draft; nil when this is no correction.
    private static func draftLength(before start: Int, cueEnd end: Int, retraction: Bool, core: [Int], tokens: [Token]) -> Int? {
        var available = 0
        if start > 0 {
            // The draft stays inside the sentence directly before the cue.
            var first = start - 1
            while first > 0, !tokens[core[first]].startsSentence { first -= 1 }
            available = min(draftWords, start - first)
        }
        for length in stride(from: available, through: 1, by: -1) where end + length <= core.count {
            let draft = core[(start - length)..<start]
            let replacement = core[end..<(end + length)]
            if replaces(draft: Array(draft), by: Array(replacement), in: tokens) { return length }
        }
        // A retraction cue needs no replacement: it takes back the clause, or nothing at the start of the text.
        return retraction ? available : nil
    }

    /// The replacement starts where the draft started and keeps most of its positions, as a restart does:
    /// "send it to Maria" / "send it to Marcus", "a large" / "a medium", "red" / "blue", "three" / "four".
    private static func replaces(draft: [Int], by replacement: [Int], in tokens: [Token]) -> Bool {
        guard related(tokens[draft[0]], tokens[replacement[0]]) else { return false }
        var unrelated = 0
        for position in 1..<max(1, draft.count) where !related(tokens[draft[position]], tokens[replacement[position]]) {
            unrelated += 1
        }
        return unrelated <= (draft.count - 1) / 3
    }

    private static func isNumberLike(_ token: Token) -> Bool {
        token.number != nil || token.text == "first" || token.text == "second"
    }

    /// The same word, or two words that can stand in for each other: two numbers, or two content words.
    private static func related(_ earlier: Token, _ later: Token) -> Bool {
        if isNumberLike(earlier) || isNumberLike(later) { return isNumberLike(earlier) && isNumberLike(later) }
        if earlier.text == later.text { return true }
        return !functionWords.contains(earlier.text) && !functionWords.contains(later.text)
    }

    // MARK: - Matching

    /// Merges runs of 2 or 3 words into one when the other text has the joined spelling,
    /// so "p m" meets "pm", "use auth session" meets "useauthsession" and "do not" meets "don't".
    static func joinSplitWords(_ input: [Token], matching otherWords: Set<String>) -> [Token] {
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
                if let candidate = candidates.first(where: otherWords.contains), !run.contains(where: { otherWords.contains($0.text) }) {
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

    // MARK: - Alignment

    /// Whether the output is the input with only allowed edits applied. The input words that are not fillers,
    /// repeats or part of a retraction must all come back, in order, and the output may have nothing else.
    ///
    /// The search keeps every output position the input read so far could have reached. Only deletable words
    /// and dictated punctuation can branch, so the set stays tiny and the search is linear in the text.
    struct Aligner {
        let input: [Token]
        let output: [Token]
        let trailing: WER.Marks
        let shouting: Bool
        /// Dictated punctuation starting at an input position: where it ends and the marks that must replace it.
        private var phrases: [Int: [(end: Int, marks: WER.Marks)]] = [:]

        init(input: [Token], output: [Token], trailing: WER.Marks, shouting: Bool) {
            self.input = input
            self.output = output
            self.trailing = trailing
            self.shouting = shouting
            let core = input.indices.filter { !input[$0].isFiller }
            for position in core.indices {
                for (words, symbol) in CleanupGuard.spokenPunctuation where position + words.count <= core.count {
                    let spoken = words.indices.allSatisfy {
                        input[core[position + $0]].text == words[$0] && input[core[position + $0]].number == nil
                    }
                    if spoken {
                        phrases[core[position], default: []].append(
                            (end: core[position + words.count - 1] + 1, marks: CleanupGuard.marks(for: symbol)))
                    }
                }
            }
        }

        /// The marks in the output between its words `j - 1` and `j`.
        private func gap(_ j: Int) -> WER.Marks { j < output.count ? output[j].marksBefore : trailing }

        func isFeasible(enforcingCase: Bool) -> Bool {
            var states = [0]
            var next: [Int] = []
            var arrivals: [Int: [Int]] = [:]
            for (i, token) in input.enumerated() {
                if let arrived = arrivals.removeValue(forKey: i) { states = Self.merged(states, arrived) }
                if let options = phrases[i] {
                    for option in options {
                        for j in states where !gap(j).isDisjoint(with: option.marks) { arrivals[option.end, default: []].append(j) }
                    }
                }
                next.removeAll(keepingCapacity: true)
                for j in states {
                    if token.isDeletable { append(j, to: &next) }
                    if j < output.count, matches(token, output[j], after: j > 0 ? output[j - 1] : nil, enforcingCase: enforcingCase) {
                        append(j + 1, to: &next)
                    }
                }
                swap(&states, &next)
                if states.isEmpty && arrivals.isEmpty { return false }
            }
            if let arrived = arrivals[input.count] { states = Self.merged(states, arrived) }
            return states.contains(output.count)
        }

        /// States are produced in order, so only neighbours can repeat.
        private func append(_ state: Int, to states: inout [Int]) {
            if states.last != state { states.append(state) }
        }

        private static func merged(_ states: [Int], _ more: [Int]) -> [Int] {
            var result: [Int] = []
            for state in (states + more).sorted() where result.last != state { result.append(state) }
            return result
        }

        private func matches(_ spoken: Token, _ written: Token, after previous: Token?, enforcingCase: Bool) -> Bool {
            if spoken.number != nil || written.number != nil {
                guard let a = spoken.number, let b = written.number else { return false }
                return !a.readings.isDisjoint(with: b.readings)
            }
            if spoken.text == written.text || Self.isPronounOne(spoken.text, written.text) {
                return !enforcingCase || shouting || CleanupGuard.caseAllows(spoken, written)
            }
            // "gigabytes" written "GB" right after its number.
            if previous?.number != nil, CleanupGuard.unitAbbreviations[spoken.text]?.contains(written.text) == true { return true }
            return false
        }

        /// "each 1" and "each one" are the same word; the number reading only applies to a quantity.
        private static func isPronounOne(_ a: String, _ b: String) -> Bool {
            (a == "1" && b == "one") || (a == "one" && b == "1")
        }
    }

    // MARK: - Why it failed

    /// Names the first thing wrong with an output the alignment rejected, from what it adds and what it lacks.
    static func diagnose(input: [Token], output: [Token], expectation: Expectation) -> (failure: Failure, added: Int) {
        let outputWords = output.filter { $0.number == nil }

        func negations(_ tokens: [Token]) -> [String: Int] {
            var result: [String: Int] = [:]
            for token in tokens { if let kind = token.negation { result[kind, default: 0] += 1 } }
            return result
        }
        let upper = negations(input.filter { !$0.isFiller && $0.number == nil })
        let lower = negations(expectation.outsideWords)
        let actual = negations(outputWords)
        for kind in Set(upper.keys).union(lower.keys).union(actual.keys) {
            if actual[kind, default: 0] < lower[kind, default: 0] || actual[kind, default: 0] > upper[kind, default: 0] {
                return (.negationChanged, 0)
            }
        }

        let said = expectation.outsideNumbers
        let written = output.compactMap(\.number)
        if written.count < said.count || written.count > expectation.allNumbers.count {
            return (.numberChanged, max(0, written.count - expectation.allNumbers.count))
        }
        var matched = 0
        for number in written where matched < said.count && !number.readings.isDisjoint(with: said[matched].readings) { matched += 1 }
        if matched < said.count { return (.numberChanged, 0) }

        // Words as a multiset, with a unit written short and "1" for "one" counted as the same word.
        var available: [String: Int] = [:]
        for token in input where token.number == nil { available[token.text, default: 0] += 1 }
        var added: [String] = []
        for token in outputWords {
            if let count = available[token.text], count > 0 {
                available[token.text] = count - 1
            } else if let spoken = available.first(where: { $0.value > 0 && unitAbbreviations[$0.key]?.contains(token.text) == true })?.key {
                available[spoken, default: 0] -= 1
            } else if let pronoun = token.text == "one" ? "1" : token.text == "1" ? "one" : nil, available[pronoun, default: 0] > 0 {
                available[pronoun, default: 0] -= 1
            } else {
                added.append(token.text)
            }
        }
        var produced: [String: Int] = [:]
        for token in outputWords { produced[token.text, default: 0] += 1 }
        var missing = 0
        for token in expectation.outsideWords {
            if let count = produced[token.text], count > 0 {
                produced[token.text] = count - 1
            } else if let short = produced.first(where: { $0.value > 0 && unitAbbreviations[token.text]?.contains($0.key) == true })?.key {
                produced[short, default: 0] -= 1
            } else if let pronoun = token.text == "one" ? "1" : token.text == "1" ? "one" : nil, produced[pronoun, default: 0] > 0 {
                produced[pronoun, default: 0] -= 1
            } else {
                missing += 1
            }
        }
        switch (added.isEmpty, missing == 0) {
        case (false, false): return (.wordChanged, added.count)
        case (false, true): return (.wordAdded, added.count)
        case (true, false): return (.contentDropped, 0)
        case (true, true):
            // Every word is there: they are out of order, or a dictated punctuation word went without its symbol.
            let kept = expectation.outsideWords.map(\.text)
            let wrote = outputWords.map(\.text)
            if kept.sorted() == wrote.sorted() && kept != wrote { return (.wordChanged, 0) }
            let said = input.filter { !$0.isFiller && $0.number == nil }.map(\.text)
            let dictatedPunctuation = spokenPunctuation.contains { contains(said, $0.words) }
            return (dictatedPunctuation ? .contentDropped : .unexplainedChange, 0)
        }
    }

    // MARK: - Case

    /// Words that stay lower case inside a sentence and are never a name, so a capital on one is Title Case.
    private static let titleFunctionWords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "from", "by", "and", "or", "but", "so", "if", "is", "are",
        "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "he", "she", "we", "they", "you", "me", "him",
        "them", "my", "your", "his", "our", "their", "do", "does", "did", "as", "than", "then", "there", "here", "not", "no", "into",
        "about", "up", "out", "just", "also", "very", "too", "lets", "thats", "im", "ive", "id", "ill",
    ]
    private static let weekdaysAndMonths: Set<String> =
        ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].reduce(into: SpokenNumber.months) { $0.insert($1) }

    /// Case may change as capitalisation and sentence breaks do, but a name, an acronym or "I" never loses
    /// its capitals, a sentence still opens with one, an acronym is short and not a common word, and the
    /// function words of a sentence stay lower case.
    static func caseAllows(_ spoken: Token, _ written: Token) -> Bool {
        if spoken.allCaps && !written.allCaps { return false }
        if written.allCaps && !spoken.allCaps && (written.text.count > 5 || (titleFunctionWords.contains(written.text))) { return false }
        if spoken.capitalized && !spoken.startsSentence && !written.capitalized { return false }
        if spoken.capitalized && spoken.startsSentence && written.startsSentence && !written.capitalized { return false }
        if !spoken.capitalized && written.capitalized && !written.startsSentence && titleFunctionWords.contains(written.text) { return false }
        return true
    }

    /// True when the dictation is all upper case, which leaves nothing to compare the output's case with.
    static func isShouting(_ text: String) -> Bool {
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if scalar.properties.isLowercase { return false }
            letters += 1
        }
        return letters >= 3
    }

    /// An output with no lower case letter at all, from a dictation that has some.
    static func changesCaseWholesale(raw: String, cleaned: String) -> Bool {
        guard isShouting(cleaned) else { return false }
        return raw.unicodeScalars.contains { $0.properties.isLowercase }
    }

    /// Capitals on most mid-sentence words that were not capitals in the dictation: "Send Report Team Today".
    static func looksTitleCased(input: [Token], output: [Token]) -> Bool {
        let names = Set(input.filter { $0.capitalized && !$0.startsSentence }.map(\.text))
        var inside = 0
        var gained = 0
        for token in output where token.number == nil && !token.startsSentence {
            inside += 1
            if token.capitalized && !token.allCaps && !names.contains(token.text) && !weekdaysAndMonths.contains(token.text) { gained += 1 }
        }
        return gained >= 3 && gained * 2 > inside
    }

    // MARK: - Identifiers and formatting

    /// An identifier in the dictation (camelCase, snake_case, S3) must come back exactly as written.
    static func identifiersChanged(raw: String, cleaned: String) -> Bool {
        Preservation.identifiers(in: raw).contains { !cleaned.contains($0) }
    }

    /// True when the output has list markers, markdown, emoji, symbols, or a question or exclamation mark that the
    /// dictation did not have: formatting is the cleaner's invention, not the speaker's.
    static func addsFormatting(raw: String, cleaned: String) -> Bool {
        if lineMarkers(in: cleaned) > lineMarkers(in: raw) { return true }
        // Markdown needs one of these four characters; most text has none, and a scan for them is cheap.
        if cleaned.utf8.contains(where: { $0 == 42 || $0 == 96 || $0 == 126 || $0 == 93 }) {
            for marker in ["**", "`", "~~", "]("] where count(of: marker, in: cleaned) > count(of: marker, in: raw) { return true }
        }
        if emojiCount(in: cleaned) > emojiCount(in: raw) { return true }
        if addsSymbols(raw: raw, cleaned: cleaned) { return true }
        return addsTerminalMark(raw: raw, cleaned: cleaned)
    }

    /// Punctuation a cleanup may add freely, and the signs a number is written with ($10, 15%, 3:30).
    private static let ordinaryPunctuation: Set<Unicode.Scalar> = [
        ".", ",", ";", ":", "?", "!", "'", "\"", "-", "(", ")", "$", "%", "\u{20AC}", "\u{00A3}", "\u{2018}", "\u{2019}", "\u{201C}",
        "\u{201D}", "\u{2013}", "\u{2014}", "\u{2026}",
    ]
    private static let emoticons: Set<String> = [
        ":)", ":-)", ":(", ":-(", ";)", ";-)", ":D", ":P", ":p", ":/", ":|", "=)", "=(", "<3", ":]", ":O", "xD", "XD",
    ]

    /// Any other symbol (an asterisk, underscore, hash, arrow, equals sign, smiley) must already be in the dictation,
    /// as often as the output has it: dictation never asks for them, so a cleaner that adds them is making things up.
    static func addsSymbols(raw: String, cleaned: String) -> Bool {
        let had = unusualSymbols(in: raw)
        for (scalar, count) in unusualSymbols(in: cleaned) where count > had[scalar, default: 0] { return true }
        return !decorations(in: cleaned).isSubset(of: decorations(in: raw))
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value == 32 || (value >= 9 && value <= 13) || (value >= 128 && scalar.properties.isWhitespace)
    }

    /// Symbols that are not letters, digits, spaces or ordinary punctuation, and how often each appears.
    private static func unusualSymbols(in text: String) -> [Unicode.Scalar: Int] {
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 128 {
                // Letters, digits, spaces and control characters are not symbols.
                if (value >= 97 && value <= 122) || (value >= 65 && value <= 90) || (value >= 48 && value <= 57) || value <= 32 || value == 127 {
                    continue
                }
                if !ordinaryPunctuation.contains(scalar) { counts[scalar, default: 0] += 1 }
                continue
            }
            let properties = scalar.properties
            if properties.isAlphabetic || properties.numericType != nil || properties.isWhitespace || ordinaryPunctuation.contains(scalar) {
                continue
            }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control: continue
            default: counts[scalar, default: 0] += 1
            }
        }
        return counts
    }

    /// Smileys, and runs of punctuation standing alone (":)", "---", "!!!"): decoration, not words.
    private static func decorations(in text: String) -> Set<String> {
        var found = Set<String>()
        var chunk = String.UnicodeScalarView()
        var length = 0
        var hasWord = false
        func finish() {
            defer {
                chunk = String.UnicodeScalarView()
                length = 0
                hasWord = false
            }
            guard length >= 2, length <= 3 || !hasWord else { return }
            let word = String(chunk)
            if emoticons.contains(word) || (length >= 3 && !hasWord) { found.insert(word) }
        }
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                finish()
            } else {
                if length < 4 || !hasWord { chunk.append(scalar) }
                length += 1
                let value = scalar.value
                if (value >= 97 && value <= 122) || (value >= 65 && value <= 90) || (value >= 48 && value <= 57)
                    || (value >= 128 && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil))
                {
                    hasWord = true
                }
            }
        }
        finish()
        return found
    }

    /// Lines that start with a bullet, a number, or a heading mark.
    static func lineMarkers(in text: String) -> Int {
        var count = 0
        let bytes = text.utf8
        var index = bytes.startIndex
        var atLineStart = true
        while index < bytes.endIndex {
            let byte = bytes[index]
            if atLineStart, byte != 32, byte != 9, byte != 10 {
                atLineStart = false
                // Only a line that starts with a bullet, a heading mark or a digit can be a list item.
                if byte == 45 || byte == 42 || byte == 62 || byte == 35 || byte == 0xE2 || (byte >= 48 && byte <= 57) || byte >= 0x80 {
                    if isMarkedLine(text[index...].prefix(while: { $0 != "\n" })) { count += 1 }
                }
            } else if byte == 10 {
                atLineStart = true
            }
            index = bytes.index(after: index)
        }
        return count
    }

    private static func isMarkedLine(_ trimmed: Substring) -> Bool {
        guard let first = trimmed.first else { return false }
        let rest = trimmed.dropFirst()
        if "-*\u{2022}>".contains(first), rest.first == " " { return true }
        if first == "#", rest.drop(while: { $0 == "#" }).first == " " { return true }
        if first.isNumber {
            let afterDigits = trimmed.drop(while: \.isNumber)
            if let mark = afterDigits.first, ".)".contains(mark), afterDigits.dropFirst().first == " " { return true }
        }
        return false
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
    /// What follows "you" in a question with no verb to invert: "you ready for the demo", "you coming tonight".
    private static let youPredicates: Set<String> = [
        "ready", "free", "done", "sure", "good", "okay", "ok", "fine", "alright", "there", "available", "set", "still", "able",
        "up", "back", "around", "interested", "hungry", "tired", "busy", "here", "in", "out",
    ]
    /// Openers of a sentence that is plainly an exclamation.
    private static let exclamationOpeners: Set<String> = [
        "wow", "congratulations", "congrats", "hooray", "yay", "ouch", "bravo", "thanks", "welcome",
    ]

    /// "We are done" must not become "We are done?": a question mark is allowed where the sentence opens like a
    /// question, where the speaker said "question mark", or where the dictation already had one. Likewise "!".
    static func addsTerminalMark(raw: String, cleaned: String) -> Bool {
        guard cleaned.utf8.contains(where: { $0 == 63 || $0 == 33 }) else { return false }
        let spoken = lex(raw).map(\.text)
        let spokenQuestionMarks = spoken.indices.filter { spoken[$0] == "question" && $0 + 1 < spoken.count && spoken[$0 + 1] == "mark" }
        let questionsSaid = count(of: "?", in: raw) + spokenQuestionMarks.count
        let bangsSaid = count(of: "!", in: raw) + spoken.indices.filter { spoken[$0] == "exclamation" }.count

        var naturalQuestions = 0
        var inventedQuestions = 0
        var naturalBangs = 0
        var inventedBangs = 0
        var sentence = ""
        for character in cleaned {
            if character == "?" {
                if opensAQuestion(lex(sentence)) { naturalQuestions += 1 } else { inventedQuestions += 1 }
                sentence = ""
            } else if character == "!" {
                if opensAnExclamation(lex(sentence)) { naturalBangs += 1 } else { inventedBangs += 1 }
                sentence = ""
            } else if ".\n".contains(character) {
                sentence = ""
            } else {
                sentence.append(character)
            }
        }
        if inventedQuestions > max(0, questionsSaid - naturalQuestions) { return true }
        return inventedBangs > max(0, bangsSaid - naturalBangs)
    }

    /// Words that lead into a question without being part of it: "Okay, what time is it?", "Hey Sam, are you free?".
    private static let questionLeaders: Set<String> = [
        "so", "and", "but", "well", "okay", "ok", "yeah", "then", "now", "anyway", "right", "hey", "hi", "hello", "please",
    ]

    /// A sentence opens like a question when its first word, the first after a leading "so" or "okay", or the
    /// first of any comma-separated clause is a question word or an auxiliary verb, or when it asks "you ready".
    private static func opensAQuestion(_ sentence: [Token]) -> Bool {
        let words = sentence.filter { !$0.isFiller }
        guard let first = words.firstIndex(where: { !questionLeaders.contains($0.text) }) else { return false }
        if questionOpeners.contains(words[first].text) { return true }
        if words.contains(where: { $0.afterComma && questionOpeners.contains($0.text) }) { return true }
        if words[first].text == "you", first + 1 < words.count {
            let next = words[first + 1].text
            return youPredicates.contains(next) || (next.count >= 5 && next.hasSuffix("ing"))
        }
        return false
    }

    private static func opensAnExclamation(_ sentence: [Token]) -> Bool {
        let words = sentence.filter { !$0.isFiller }
        guard let first = words.firstIndex(where: { !questionLeaders.contains($0.text) }) else { return false }
        let word = words[first].text
        if exclamationOpeners.contains(word) { return true }
        if word == "thank", first + 1 < words.count, words[first + 1].text == "you" { return true }
        if word == "what", first + 1 < words.count, ["a", "an"].contains(words[first + 1].text) { return true }
        return word == "happy" && first + 1 < words.count && ["birthday", "new", "anniversary"].contains(words[first + 1].text)
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

    private static let openerWords: [[String]] = openers.map { lex($0).map(\.text) }
    private static let closerWords: [[String]] = closers.map { lex($0).map(\.text) }

    /// `input` should already have its um/uh fillers removed, so "um sure that works" may become "Sure, that works".
    static func hasChattyFraming(input: [String], output: [String]) -> Bool {
        for words in openerWords where output.starts(with: words) && !input.starts(with: words) {
            return true
        }
        for words in closerWords where contains(output, words) && !contains(input, words) {
            return true
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
