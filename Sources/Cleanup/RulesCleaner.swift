import FlowKit
import Foundation

/// Deterministic, instant cleanup that needs no model.
///
/// It removes um/uh fillers and comma-bounded "you know", collapses stutters and immediately repeated
/// words, turns clearly spoken punctuation and line commands into the real thing, restores sentence
/// capitalization and spacing, and swaps dictionary terms for their canonical spelling. Text that is
/// already clean passes through unchanged. It does not resolve self-corrections; that takes a model.
///
/// Whitespace contract: line structure survives (every blank line, each line's leading indentation, tabs between
/// words). Only these are normalized: CRLF becomes LF, a run of spaces inside a line becomes one space, and
/// trailing whitespace is dropped. Input with no words in it ("...", "?") is returned trimmed but otherwise as is.
public struct RulesCleaner: TextCleaner {
    public let name = "rules"

    private struct Entry: Sendable {
        let words: [String]
        let canonical: String
    }

    private let entries: [Entry]
    private let protectedSpellings: Set<String>

    /// - Parameter dictionary: spoken term (any case, may be several words) to canonical spelling,
    ///   for example `["cube control": "kubectl"]`. Supplied by the caller; nothing is built in.
    public init(dictionary: [String: String] = [:]) {
        var entries: [Entry] = []
        for (term, canonical) in dictionary {
            let words = term.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard !words.isEmpty, !canonical.isEmpty else { continue }
            entries.append(Entry(words: words, canonical: canonical))
        }
        // Longest phrase first so "flow kit pro" wins over "flow kit".
        self.entries = entries.sorted { ($0.words.count, $0.canonical) > ($1.words.count, $1.canonical) }
        self.protectedSpellings = Set(dictionary.values)
    }

    public func prepare() async throws {}

    public func clean(_ raw: String) async throws -> String {
        cleaned(raw)
    }

    public func cleaned(_ raw: String) -> String {
        var tokens = Self.tokenize(raw)
        guard tokens.contains(where: \.isWord) else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        let wasUncased = tokens.first(where: \.isWord)?.core.first?.isLowercase == true

        applySpokenCommands(&tokens)
        removeFillers(&tokens)
        collapseStutters(&tokens)
        applyDictionary(&tokens)
        fixPronounI(&tokens)
        capitalizeSentences(&tokens)
        if wasUncased { closeFinalSentence(&tokens) }
        return Self.render(tokens)
    }

    // MARK: - Tokens

    /// A whitespace-separated chunk split into leading punctuation, the word itself, and trailing punctuation,
    /// or a line break. Joining `lead + core + trail` always reproduces the original chunk.
    private struct Token {
        var lead = ""
        var core = ""
        var trail = ""
        var breaks = 0
        /// The gap before this token on its line: a single space, or the original run when it held a tab.
        var space = " "
        /// Whether the token began a line in the input, and the indentation it had there.
        var startsLine = false
        var indent = ""

        var isBreak: Bool { breaks > 0 }
        var isWord: Bool { breaks == 0 && !core.isEmpty }
        var key: String { core.lowercased() }
    }

    private static let leadCharacters: Set<Character> = ["(", "[", "{", "\"", "\u{201C}"]
    private static let trailCharacters: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}", ")", "]", "}", "\"", "\u{201D}"]
    private static let stopCharacters: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\u{2026}"]

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var gap = ""
        var pendingBreaks = 0
        var atLineStart = true

        func flush() {
            guard !current.isEmpty else { return }
            if pendingBreaks > 0, !tokens.isEmpty { tokens.append(Token(breaks: pendingBreaks)) }
            var token = split(current)
            token.startsLine = atLineStart
            if atLineStart {
                token.indent = gap
            } else if gap.contains("\t") {
                token.space = gap
            }
            tokens.append(token)
            current = ""
            gap = ""
            pendingBreaks = 0
            atLineStart = false
        }

        for character in text {
            if character.isNewline {
                flush()
                pendingBreaks += 1
                gap = ""
                atLineStart = true
            } else if character.isWhitespace {
                flush()
                gap.append(character)
            } else {
                current.append(character)
            }
        }
        flush()

        // A lone "," or "." (as in "hello , world") belongs to the word before it.
        var merged: [Token] = []
        for token in tokens {
            if token.core.isEmpty, !token.isBreak, !token.lead.isEmpty, token.lead.allSatisfy(stopCharacters.contains),
                let last = merged.last, last.isWord
            {
                merged[merged.count - 1].trail += token.lead
            } else {
                merged.append(token)
            }
        }
        return merged
    }

    private static func split(_ chunk: String) -> Token {
        let characters = Array(chunk)
        var start = 0
        while start < characters.count, leadCharacters.contains(characters[start]) { start += 1 }
        var end = characters.count
        while end > start, trailCharacters.contains(characters[end - 1]) { end -= 1 }
        if start == end { return Token(lead: chunk) }
        return Token(
            lead: String(characters[0..<start]),
            core: String(characters[start..<end]),
            trail: String(characters[end...]))
    }

    private static func render(_ tokens: [Token]) -> String {
        var output = ""
        var atLineStart = true
        for token in tokens {
            if token.isBreak {
                output += String(repeating: "\n", count: token.breaks)
                atLineStart = true
                continue
            }
            if atLineStart {
                if token.startsLine { output += token.indent }
            } else {
                output += token.space
            }
            output += token.lead + token.core + token.trail
            atLineStart = false
        }
        // Keep the first line's indentation; only blank lines before it and whitespace after the end go.
        while output.first?.isNewline == true { output.removeFirst() }
        while output.last?.isWhitespace == true { output.removeLast() }
        return output
    }

    private static func endsSentence(_ trail: String) -> Bool {
        trail.contains(where: sentenceEnders.contains)
    }

    // MARK: - Spoken commands

    /// Words that, right before "period" or "new line", mean the speaker is talking about the thing, not commanding it.
    private static let mentionPrefixes: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its",
        "no", "one", "each", "every", "another", "any", "some", "of", "with", "without", "add", "adding", "insert",
        "put", "use", "using", "type", "typing", "press", "key", "start", "begin", "create", "make", "need", "want",
        "oxford", "serial", "trailing", "missing", "extra", "stray", "last", "first", "decimal", "big", "red",
    ]
    private static let periodNouns: Set<String> = [
        "time", "grace", "trial", "billing", "waiting", "same", "whole", "entire", "cooling", "probation", "holding",
    ]
    private static let lineNounFollowers: Set<String> = ["character", "characters", "break", "breaks", "of"]

    private func applySpokenCommands(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            guard tokens[i].isWord, i > 0, tokens[i - 1].isWord else { i += 1; continue }
            let previous = tokens[i - 1]
            let key = tokens[i].key
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            let nextKey = next?.isWord == true ? next?.key : nil
            guard !Self.mentionPrefixes.contains(previous.key) else { i += 1; continue }

            var replacement: String?
            var length = 1
            // Punctuation words only count as commands right after an unpunctuated word.
            switch previous.trail.isEmpty ? key : "" {
            case "comma":
                replacement = ","
            case "period":
                let atEnd = next == nil || next?.isBreak == true || (nextKey == "new" && Self.isLineCommand(tokens, at: i + 1))
                let nextIsCapitalized = next?.core.first?.isUppercase == true
                if (atEnd || nextIsCapitalized) && !Self.periodNouns.contains(previous.key) { replacement = "." }
            case "full" where nextKey == "stop":
                replacement = "."
                length = 2
            case "question" where nextKey == "mark":
                replacement = "?"
                length = 2
            case "exclamation" where nextKey == "point" || nextKey == "mark":
                replacement = "!"
                length = 2
            default:
                break
            }
            // "period" with its own punctuation ("period.") is still the command; anything else is not.
            let commandWords = tokens[i..<(i + length)]
            if replacement != nil, commandWords.dropLast().contains(where: { !$0.trail.isEmpty || !$0.lead.isEmpty }) {
                replacement = nil
            }
            if let replacement {
                tokens[i - 1].trail = replacement
                tokens.removeSubrange(i..<(i + length))
                continue
            }

            if key == "new", let nextKey, nextKey == "line" || nextKey == "paragraph", Self.isLineCommand(tokens, at: i) {
                tokens.replaceSubrange(i..<(i + 2), with: [Token(breaks: nextKey == "line" ? 1 : 2)])
                continue
            }
            if key == "newline" {
                tokens.replaceSubrange(i..<(i + 1), with: [Token(breaks: 1)])
                continue
            }
            i += 1
        }
        // A command at the very end leaves a trailing break; drop it.
        while tokens.last?.isBreak == true { tokens.removeLast() }
    }

    /// "new line" / "new paragraph" at `index` is a command unless the next word makes it a noun phrase.
    private static func isLineCommand(_ tokens: [Token], at index: Int) -> Bool {
        guard index + 1 < tokens.count, tokens[index].isWord, tokens[index].key == "new" else { return false }
        let kind = tokens[index + 1]
        guard kind.isWord, kind.key == "line" || kind.key == "paragraph" else { return false }
        guard kind.lead.isEmpty, tokens[index].lead.isEmpty, tokens[index].trail.isEmpty else { return false }
        if index + 2 < tokens.count, tokens[index + 2].isWord, lineNounFollowers.contains(tokens[index + 2].key) {
            return false
        }
        return true
    }

    // MARK: - Fillers

    private static let introWords: Set<String> = [
        "so", "well", "however", "anyway", "anyways", "okay", "ok", "yes", "no", "yeah", "actually", "basically",
        "honestly", "first", "second", "third", "finally", "then", "also", "now", "right", "sure", "therefore",
        "meanwhile", "still", "instead", "besides", "otherwise", "hey", "hi", "hello",
    ]

    /// um, uh, er, hmm and their stretched spellings ("ummm"). All-caps words such as "ER" are left alone.
    private static func isFillerWord(_ core: String) -> Bool {
        if core.count > 1, core.filter(\.isUppercase).count > 1 { return false }
        var collapsed = ""
        for character in core.lowercased() where character != collapsed.last { collapsed.append(character) }
        switch collapsed {
        case "um", "uh", "uhm", "er", "erm", "hm", "mhm": return true
        case "m": return core.count >= 2
        default: return false
        }
    }

    private func removeFillers(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            guard tokens[i].isWord else { i += 1; continue }
            let span = Self.fillerSpan(tokens, at: i)
            guard span > 0 else { i += 1; continue }

            let punctuation = tokens[i + span - 1].trail
            let hasNext = i + span < tokens.count && tokens[i + span].isWord
            if i > 0, tokens[i - 1].isWord {
                let previous = i - 1
                if Self.endsSentence(punctuation) {
                    if !Self.endsSentence(tokens[previous].trail) { tokens[previous].trail = punctuation }
                } else if !hasNext {
                    if tokens[previous].trail == "," { tokens[previous].trail = "" }
                } else if tokens[previous].trail == ",", punctuation == ",", !Self.introWords.contains(tokens[previous].key) {
                    tokens[previous].trail = ""
                }
            }
            tokens.removeSubrange(i..<(i + span))
        }
    }

    /// Number of tokens at `index` that form a filler, or 0.
    private static func fillerSpan(_ tokens: [Token], at index: Int) -> Int {
        let token = tokens[index]
        guard token.lead.isEmpty else { return 0 }
        let previous = index > 0 ? tokens[index - 1] : nil
        if isFillerWord(token.core) {
            // "10 mm" is a unit, not a hum.
            if token.key.allSatisfy({ $0 == "m" }), previous?.core.contains(where: \.isNumber) == true { return 0 }
            return 1
        }
        let afterComma = previous?.isWord == true && previous?.trail == ","
        let startsSentence = previous == nil || previous?.isBreak == true || (previous?.isWord == true && endsSentence(previous?.trail ?? ""))
        let hasNext = index + 1 < tokens.count && tokens[index + 1].isWord

        // "..., you know, ..." and "You know, ..." but never "do you know the way" or "as you know, the".
        if token.key == "you", token.trail.isEmpty, hasNext, tokens[index + 1].key == "know", tokens[index + 1].lead.isEmpty {
            let trail = tokens[index + 1].trail
            let nextAfter = index + 2 < tokens.count ? tokens[index + 2] : nil
            let atEnd = nextAfter == nil || nextAfter?.isBreak == true
            if afterComma, !trail.isEmpty && trail.allSatisfy(stopCharacters.contains) || atEnd { return 2 }
            if startsSentence, trail == "," { return 2 }
        }
        // ", like, " as a verbal tic.
        if token.key == "like", token.trail == ",", afterComma || startsSentence { return 1 }
        return 0
    }

    // MARK: - Stutters and repeats

    /// Words that are legitimately doubled, so "had had" and "bye bye" survive.
    private static let legitimateDoubles: Set<String> = [
        "had", "that", "very", "really", "bye", "no", "so", "ha", "yeah", "hello", "sorry", "please", "knock", "go",
    ]
    /// Short function words that stutter across a comma: "I, I think".
    private static let commaStutterWords: Set<String> = [
        "i", "we", "you", "they", "he", "she", "it", "the", "a", "an", "to", "of", "in", "on", "for", "with", "and", "but",
        "if", "my", "our", "your",
    ]

    private func collapseStutters(_ tokens: inout [Token]) {
        // Word fragments: "th- the" and "w-w-we".
        var i = 0
        while i < tokens.count {
            guard tokens[i].isWord else { i += 1; continue }
            if let repaired = Self.repairLetterStutter(tokens[i].core) {
                tokens[i].core = repaired
            }
            let core = tokens[i].core
            if core.count >= 2, core.count <= 5, core.hasSuffix("-"), core.dropLast().allSatisfy(\.isLetter),
                i + 1 < tokens.count, tokens[i + 1].isWord,
                tokens[i + 1].key.hasPrefix(core.dropLast().lowercased()), tokens[i + 1].core.count > core.count - 1
            {
                tokens.remove(at: i)
                continue
            }
            i += 1
        }

        // Repeated blocks of up to three words.
        var changed = true
        while changed {
            changed = false
            var start = 0
            while start < tokens.count {
                var collapsed = false
                for length in stride(from: 3, through: 1, by: -1) where start + 2 * length <= tokens.count {
                    let first = tokens[start..<(start + length)]
                    let second = tokens[(start + length)..<(start + 2 * length)]
                    guard first.allSatisfy(\.isWord), second.allSatisfy(\.isWord) else { continue }
                    guard zip(first, second).allSatisfy({ $0.key == $1.key }) else { continue }
                    guard !first.contains(where: { $0.core.contains(where: \.isNumber) }) else { continue }
                    guard !first.contains(where: { !$0.lead.isEmpty }), !second.dropFirst().contains(where: { !$0.lead.isEmpty }) else { continue }
                    // No punctuation inside or between the blocks, except a comma after a lone function word.
                    let innerPunctuation = first.dropLast().contains { !$0.trail.isEmpty } || second.dropLast().contains { !$0.trail.isEmpty }
                    guard !innerPunctuation else { continue }
                    let lastTrail = first.last?.trail ?? ""
                    if !lastTrail.isEmpty {
                        guard length == 1, lastTrail == ",", Self.commaStutterWords.contains(first[start].key) else { continue }
                    }
                    if length == 1, lastTrail.isEmpty, Self.legitimateDoubles.contains(first[start].key) { continue }

                    // Keep the second copy, which carries the punctuation, but keep a sentence-initial capital.
                    let wasCapitalized = tokens[start].core.first?.isUppercase == true
                    tokens.removeSubrange(start..<(start + length))
                    if wasCapitalized, Self.isPlainLowercase(tokens[start].core) {
                        tokens[start].core = Self.capitalizingFirst(tokens[start].core)
                    }
                    collapsed = true
                    changed = true
                    break
                }
                if !collapsed { start += 1 }
            }
        }
    }

    /// "w-w-we" becomes "we"; anything that is not a stuttered first letter is left alone.
    private static func repairLetterStutter(_ core: String) -> String? {
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let word = parts.last, word.count >= 2, let letter = word.first, letter.isLetter else { return nil }
        let stutters = parts.dropLast()
        guard stutters.allSatisfy({ $0.count == 1 && $0.lowercased() == letter.lowercased() }) else { return nil }
        return parts[0].first?.isUppercase == true ? capitalizingFirst(word) : word
    }

    // MARK: - Dictionary

    private func applyDictionary(_ tokens: inout [Token]) {
        guard !entries.isEmpty else { return }
        var i = 0
        while i < tokens.count {
            for entry in entries where i + entry.words.count <= tokens.count {
                let span = tokens[i..<(i + entry.words.count)]
                let matches = span.enumerated().allSatisfy { offset, token in
                    token.isWord && token.key == entry.words[offset] && (offset == entry.words.count - 1 || token.trail.isEmpty)
                }
                guard matches, let first = span.first, let last = span.last else { continue }
                var replacement = first
                replacement.core = entry.canonical
                replacement.trail = last.trail
                tokens.replaceSubrange(i..<(i + entry.words.count), with: [replacement])
                break
            }
            i += 1
        }
    }

    // MARK: - Capitalization

    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "etc", "jr", "sr", "inc", "ltd"]

    private static func isPlainLowercase(_ core: String) -> Bool {
        guard let first = core.first, first.isLetter else { return false }
        return core.allSatisfy { $0.isLowercase || $0 == "'" || $0 == "\u{2019}" || $0 == "-" }
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func fixPronounI(_ tokens: inout [Token]) {
        let forms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "i\u{2019}m", "i\u{2019}ll", "i\u{2019}ve", "i\u{2019}d"]
        for index in tokens.indices where tokens[index].isWord {
            let core = tokens[index].core
            if forms.contains(core), !protectedSpellings.contains(core) {
                tokens[index].core = Self.capitalizingFirst(core)
            }
        }
    }

    private func capitalizeSentences(_ tokens: inout [Token]) {
        var atStart = true
        for index in tokens.indices {
            if tokens[index].isBreak {
                atStart = true
                continue
            }
            guard tokens[index].isWord else { continue }
            let core = tokens[index].core
            if atStart, Self.isPlainLowercase(core), !protectedSpellings.contains(core) {
                tokens[index].core = Self.capitalizingFirst(core)
            }
            let abbreviation = Self.abbreviations.contains(tokens[index].key) || core.contains(".")
            let trail = tokens[index].trail
            // "Well... maybe" trails off and carries on; it does not start a new sentence.
            let trailsOff = trail.contains("...") || trail.contains("\u{2026}")
            atStart = trail.contains(where: { $0 == "!" || $0 == "?" }) || (Self.endsSentence(trail) && !abbreviation && !trailsOff)
        }
    }

    /// Words that open a question when the text has no punctuation to say so.
    private static let questionOpeners: Set<String> = [
        "what", "who", "whom", "whose", "where", "when", "why", "which", "how",
        "is", "are", "was", "were", "am", "does", "did", "can", "could", "would", "should",
    ]

    /// Text that arrived uncased (lowercase, no punctuation) gets a closing mark when it reads as a sentence:
    /// "?" if it opens like a question, otherwise ".".
    private func closeFinalSentence(_ tokens: inout [Token]) {
        guard tokens.filter(\.isWord).count >= 3, let lastIndex = tokens.lastIndex(where: \.isWord) else { return }
        let last = tokens[lastIndex]
        guard last.trail.isEmpty, last.core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" }) else { return }

        var first = lastIndex
        while first > 0, tokens[first - 1].isWord, !Self.endsSentence(tokens[first - 1].trail) { first -= 1 }
        let opener = tokens[first].key
        let second = first + 1 < tokens.count && tokens[first + 1].isWord ? tokens[first + 1].key : ""
        let isQuestion = Self.questionOpeners.contains(opener) && !(opener == "how" && second == "to") && !(opener == "what" && second == "a")
        tokens[lastIndex].trail = isQuestion ? "?" : "."
    }
}
