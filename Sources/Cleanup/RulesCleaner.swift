import FlowKit
import Foundation

/// Deterministic, instant cleanup that needs no model.
///
/// It removes um/uh fillers and comma-bounded "you know", collapses stutters and immediately repeated
/// words, turns clearly spoken punctuation and line commands into the real thing, restores sentence
/// capitalization and spacing, and swaps dictionary terms for their canonical spelling. Text that is
/// already clean passes through unchanged. It does not resolve self-corrections; that takes a model.
///
/// When unsure it leaves the text alone: a punctuation word is a command only when nothing around it makes it a
/// noun ("a long period", "split on comma"), a repeat is a stutter only when it reads like one ("the the", not
/// "Bora Bora" or "ho ho ho"), and "?" is added only to a plainly spoken question.
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

    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its", "no",
        "each", "every", "another", "any", "some", "many", "much", "few", "several",
    ]
    /// Prepositions and conjunctions: a clause cannot end on them, so a punctuation word after one is a noun ("on comma").
    private static let connectives: Set<String> = [
        "of", "with", "without", "on", "onto", "after", "before", "at", "in", "into", "per", "between", "via", "by",
        "from", "to", "as", "than", "and", "or", "but", "nor", "during", "over", "under", "through", "for", "about",
    ]
    /// Verbs that take a punctuation name as their bare object: "strip newline", "put period", "replace comma".
    private static let editVerbs: Set<String> = [
        "add", "adds", "added", "adding", "insert", "inserts", "inserted", "inserting", "put", "puts", "putting",
        "type", "types", "typed", "typing", "press", "presses", "pressed", "pressing", "hit", "hits", "hitting",
        "remove", "removes", "removed", "removing", "delete", "deletes", "deleted", "deleting",
        "strip", "strips", "stripped", "stripping", "trim", "trims", "trimmed", "trimming",
        "split", "splits", "splitting", "join", "joins", "joined", "joining",
        "replace", "replaces", "replaced", "replacing", "append", "appends", "appended", "appending",
        "escape", "escapes", "escaped", "escaping", "enter", "change", "changes", "changed", "changing",
        "swap", "swaps", "swapped", "swapping", "convert", "converts", "converted", "converting",
        "say", "says", "said", "saying", "key", "character", "symbol", "sign", "word", "words",
        "print", "prints", "printed", "printing", "write", "writes", "wrote", "writing", "output", "outputs", "echo",
        "emit", "emits", "prepend", "expect", "expects", "ignore", "ignores", "skip", "skips", "keep", "keeps",
        "preserve", "preserves", "count", "counts", "handle", "handles", "contain", "contains", "include", "includes",
        "allow", "allows", "parse", "parses", "treat", "treats", "treated", "read", "reads",
    ]
    /// Words that describe the thing: "long period", "trailing newline", "Oxford comma".
    private static let modifiers: Set<String> = [
        "long", "short", "next", "previous", "same", "whole", "entire", "final", "oxford", "serial", "trailing",
        "leading", "missing", "extra", "stray", "decimal", "single", "double", "inverted", "forgotten", "wrong",
        "second", "third", "fourth", "fifth", "more", "additional", "other", "proper", "correct",
    ]
    /// Verbs that take "period" or "new line" as an object only sometimes: "use period as the delimiter" mentions it,
    /// "that is what we use period" does not. They block a command only while the sentence carries on lowercase.
    private static let softPrefixes: Set<String> = [
        "use", "uses", "using", "make", "makes", "making", "need", "needs", "needed", "want", "wants", "wanted",
        "start", "starts", "starting", "begin", "begins", "beginning", "create", "creates", "creating",
    ]
    /// Numbers are items in a list ("item one comma item two") unless a determiner or verb in front makes them a
    /// count of the thing ("put one comma", "the first comma").
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "first", "last",
    ]
    private static let quantifiers: Set<String> = ["only", "just", "exactly", "least", "most", "than"]
    /// "period" is a noun after these: "the waiting period", "the holiday period".
    private static let periodCompounds: Set<String> = [
        "time", "grace", "trial", "billing", "waiting", "cooling", "probation", "holding", "holiday", "holidays",
        "summer", "winter", "school", "ice", "dark", "quiet", "busy", "transition", "reporting", "review", "notice",
        "testing", "sampling", "fiscal", "financial", "historical", "recovery", "development", "vacation",
    ]
    private static let mentionPrefixes = determiners.union(connectives).union(editVerbs).union(modifiers)

    private static let nameFollowers: Set<String> = ["key", "keys", "button", "symbol", "symbols", "sign", "icon", "character", "characters"]
    private static let commaFollowers = nameFollowers.union(["separated", "delimited", "splice", "splices", "placement", "usage"])
    private static let lineFollowers = nameFollowers.union([
        "break", "breaks", "of", "item", "items", "manager", "managers", "feed", "ending", "endings", "separator",
        "delimiter", "escape", "sequence",
    ])

    private enum Command {
        case mark(String, words: Int)
        case lineBreak(Int, words: Int)
    }

    private func applySpokenCommands(_ tokens: inout [Token]) {
        // Text the speech model already punctuated needs more evidence before a word is taken for a command.
        let punctuated = tokens.contains { $0.isWord && Self.endsSentence($0.trail) }
        var i = 1
        while i < tokens.count {
            guard tokens[i].isWord, let command = Self.command(at: i, in: tokens, punctuated: punctuated) else {
                i += 1
                continue
            }
            switch command {
            case .mark(let mark, let words):
                tokens[i - 1].trail = mark
                tokens.removeSubrange(i..<(i + words))
            case .lineBreak(let count, let words):
                tokens.replaceSubrange(i..<(i + words), with: [Token(breaks: count)])
            }
        }
        // Two breaks in a row make one blank-line break ("new line new line"), never more than a spoken paragraph.
        var merged: [Token] = []
        for token in tokens {
            if token.isBreak, let last = merged.last, last.isBreak {
                merged[merged.count - 1].breaks = max(last.breaks, token.breaks, min(2, last.breaks + token.breaks))
            } else {
                merged.append(token)
            }
        }
        tokens = merged
        // A command at the very end leaves a trailing break; drop it.
        while tokens.last?.isBreak == true { tokens.removeLast() }
    }

    /// The spoken command that starts at `index`, if the words there are plainly a command and not a mention of
    /// the thing ("a long period", "split on comma", "the new line character").
    private static func command(at index: Int, in tokens: [Token], punctuated: Bool) -> Command? {
        let previous = tokens[index - 1]
        guard previous.isWord || previous.isBreak else { return nil }
        let key = tokens[index].key
        let nextKey = index + 1 < tokens.count && tokens[index + 1].isWord ? tokens[index + 1].key : nil

        var mark: String?
        var breaks = 0
        var words = 1
        var followers = nameFollowers
        switch key {
        case "comma":
            mark = ","
            followers = commaFollowers
        case "period":
            mark = "."
        case "full" where nextKey == "stop":
            (mark, words) = (".", 2)
        case "question" where nextKey == "mark":
            (mark, words) = ("?", 2)
        case "exclamation" where nextKey == "point" || nextKey == "mark":
            (mark, words) = ("!", 2)
        case "new" where nextKey == "line":
            (breaks, words) = (1, 2)
            followers = lineFollowers
        case "new" where nextKey == "paragraph":
            (breaks, words) = (2, 2)
            followers = lineFollowers
        case "newline" where !punctuated:
            // The one-word form is mostly the name of the character, so text that is already punctuated keeps it.
            breaks = 1
            followers = lineFollowers
        default:
            return nil
        }

        // Punctuation goes on a word; only a line break can follow another break.
        if mark != nil, !(previous.isWord && previous.trail.isEmpty) { return nil }
        guard previous.isWord || breaks > 0 else { return nil }

        // The command's own words carry no punctuation: "period." is the word followed by a full stop, which is how
        // a sentence ending in the noun looks. The one exception is a line command the speech model punctuated as
        // its own sentence ("Thanks. New line. Best regards.").
        let span = tokens[index..<(index + words)]
        let sentenceOfItsOwn = breaks > 0 && endsSentence(previous.trail)
        guard span.allSatisfy({ $0.isWord && $0.lead.isEmpty }), span.dropLast().allSatisfy({ $0.trail.isEmpty }),
            span.last?.trail.isEmpty == true || sentenceOfItsOwn
        else { return nil }

        let after = index + words < tokens.count ? tokens[index + words] : nil
        if let after, after.isWord, followers.contains(after.key) { return nil }

        if previous.isWord, previous.trail.isEmpty, isMention(tokens, at: index, after: after, punctuated: punctuated) {
            return nil
        }

        if key == "period" {
            // "period" only ends a sentence when something plainly follows it.
            guard !periodCompounds.contains(previous.key) else { return nil }
            let capitalized = after?.isWord == true && after?.lead.isEmpty == true && after?.core.first?.isUppercase == true
            var lineCommandFollows = false
            if after?.key == "new", case .lineBreak = command(at: index + 1, in: tokens, punctuated: punctuated) { lineCommandFollows = true }
            let atEnd = after == nil || after?.isBreak == true
            guard capitalized || lineCommandFollows || (atEnd && !punctuated) else { return nil }
        }

        if let mark { return .mark(mark, words: words) }
        return .lineBreak(breaks, words: words)
    }

    /// Whether the word before the command makes it the name of a thing rather than an instruction.
    private static func isMention(_ tokens: [Token], at index: Int, after: Token?, punctuated: Bool) -> Bool {
        let previous = tokens[index - 1].key
        if mentionPrefixes.contains(previous) { return true }
        if softPrefixes.contains(previous) {
            // Still a mention only while the sentence carries on in lowercase.
            return after?.isWord == true && after?.lead.isEmpty == true && after?.core.first?.isLowercase == true
        }
        if numberWords.contains(previous) {
            if punctuated { return true }
            guard index >= 2, tokens[index - 2].isWord, tokens[index - 2].trail.isEmpty else { return false }
            let earlier = tokens[index - 2].key
            return mentionPrefixes.contains(earlier) || softPrefixes.contains(earlier) || quantifiers.contains(earlier)
        }
        guard punctuated else { return false }
        // Text the speech model already punctuated: a determiner, preposition or editing verb anywhere earlier in
        // the clause ("during the Victorian period", "add one more comma") suggests a noun phrase, so leave it.
        for position in stride(from: index - 1, through: max(0, index - 3), by: -1) {
            let token = tokens[position]
            guard token.isWord, position == index - 1 || token.trail.isEmpty else { break }
            if mentionPrefixes.contains(token.key) { return true }
        }
        return false
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
        // Built into a new array: removing each filler in place would make a long run of them quadratic.
        var kept: [Token] = []
        kept.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            let span = tokens[i].isWord ? Self.fillerSpan(tokens, at: i, previous: kept.last) : 0
            guard span > 0 else {
                kept.append(tokens[i])
                i += 1
                continue
            }

            let punctuation = tokens[i + span - 1].trail
            let hasNext = i + span < tokens.count && tokens[i + span].isWord
            if let previous = kept.last, previous.isWord {
                let last = kept.count - 1
                if Self.endsSentence(punctuation) {
                    if !Self.endsSentence(previous.trail) { kept[last].trail = punctuation }
                } else if !hasNext {
                    if previous.trail == "," { kept[last].trail = "" }
                } else if previous.trail == ",", punctuation == ",", !Self.introWords.contains(previous.key) {
                    kept[last].trail = ""
                }
            }
            i += span
        }
        tokens = kept
    }

    /// Number of tokens at `index` that form a filler, or 0.
    private static func fillerSpan(_ tokens: [Token], at index: Int, previous: Token?) -> Int {
        let token = tokens[index]
        guard token.lead.isEmpty else { return 0 }
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

    /// Function words that are legitimately doubled, so "had had" and "gave her her keys" survive. A content word is
    /// never collapsed, so "bye bye" and "boo boo" need no entry here.
    private static let legitimateDoubles: Set<String> = ["had", "that", "so", "her"]
    /// Words people stutter on: pronouns, articles, prepositions, conjunctions, copulas and their contractions. A
    /// doubled one is a stutter wherever it sits, and these are the only single words that are collapsed on their own.
    private static let stutterWords: Set<String> = [
        "i", "we", "you", "he", "she", "it", "they", "me", "us", "him", "them", "the", "a", "an", "my", "our", "your",
        "his", "her", "its", "their", "this", "that", "these", "those", "is", "are", "was", "were", "am", "be", "been",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "about", "into", "and", "but", "or", "if", "so",
        "because", "than", "then", "not", "there", "what", "when", "where", "who", "how", "why", "which", "more",
        "some", "any", "all", "just", "also", "i'm", "i'll", "i've", "i'd", "we're", "we'll", "we've", "we'd", "you're",
        "you'll", "you've", "he's", "she's", "it's", "they're", "that's", "there's", "don't", "didn't", "can't",
        "won't", "isn't",
    ]
    /// Modals and auxiliaries double as nouns and names ("a can can hold", "Will will come"), so they count as a stutter
    /// only right behind a personal pronoun: "we would would like". "do", "does" and "did" are left out entirely, since
    /// "I do do care" is emphatic.
    private static let auxiliaryWords: Set<String> = [
        "can", "will", "would", "could", "should", "may", "might", "must", "have", "has",
    ]
    private static let personalPronouns: Set<String> = ["i", "we", "you", "he", "she", "it", "they"]
    /// Every word that may start a repeated phrase ("we should we should") or follow a stuttered first letter.
    private static let functionWords = stutterWords.union(auxiliaryWords).union(["do", "does", "did", "had"])
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

        // Repeated blocks of up to three words. Each pass is linear; a second one is only needed when a removal puts two
        // more copies side by side ("the cat the the cat"), so the number of passes is capped.
        for _ in 0..<Self.maxCollapsePasses {
            guard Self.collapseRepeatedBlocks(&tokens) else { break }
        }
    }

    private static let maxCollapsePasses = 6
    private static let longestRepeatedBlock = 3

    /// One left-to-right pass that drops the first copy of every repeated block, keeping the second, which carries
    /// the punctuation. Returns whether anything was dropped.
    ///
    /// The tokens are copied into a new array instead of removed in place, and a block is judged from the few tokens
    /// around it, so a word repeated thousands of times costs time in proportion to its length, not its square.
    private static func collapseRepeatedBlocks(_ tokens: inout [Token]) -> Bool {
        var kept: [Token] = []
        kept.reserveCapacity(tokens.count)
        var position = 0
        var changed = false
        scan: while position < tokens.count {
            if tokens[position].isWord, repeatsSoon(tokens, at: position) {
                for length in stride(from: longestRepeatedBlock, through: 1, by: -1) where position + 2 * length <= tokens.count {
                    guard isStutter(tokens, start: position, length: length, previous: kept.last) else { continue }
                    let wasCapitalized = tokens[position].core.first?.isUppercase == true
                    position += length
                    // Keep a sentence-initial capital.
                    if wasCapitalized, isPlainLowercase(tokens[position].core) {
                        tokens[position].core = capitalizingFirst(tokens[position].core)
                    }
                    changed = true
                    continue scan
                }
            }
            kept.append(tokens[position])
            position += 1
        }
        if changed { tokens = kept }
        return changed
    }

    /// A cheap test that the word at `index` comes back within a block's reach, so most tokens skip the full check.
    private static func repeatsSoon(_ tokens: [Token], at index: Int) -> Bool {
        let key = tokens[index].key
        return (1...longestRepeatedBlock).contains { index + $0 < tokens.count && tokens[index + $0].key == key }
    }

    /// Whether the block of `length` words at `start` is immediately repeated by a stutter rather than on purpose.
    /// `previous` is the token before the block, which may already have left `tokens`.
    private static func isStutter(_ tokens: [Token], start: Int, length: Int, previous: Token?) -> Bool {
        let first = tokens[start..<(start + length)]
        let second = tokens[(start + length)..<(start + 2 * length)]
        guard first.allSatisfy(\.isWord), second.allSatisfy(\.isWord) else { return false }
        guard zip(first, second).allSatisfy({ $0.key == $1.key }) else { return false }
        guard !first.contains(where: { $0.core.contains(where: \.isNumber) }) else { return false }
        guard !first.contains(where: { !$0.lead.isEmpty }), !second.dropFirst().contains(where: { !$0.lead.isEmpty }) else { return false }
        // No punctuation inside or between the blocks, except a comma after a lone function word.
        let innerPunctuation = first.dropLast().contains { !$0.trail.isEmpty } || second.dropLast().contains { !$0.trail.isEmpty }
        guard !innerPunctuation else { return false }
        let lastTrail = first.last?.trail ?? ""
        if !lastTrail.isEmpty {
            guard length == 1, lastTrail == ",", commaStutterWords.contains(first[start].key) else { return false }
        }

        if length == 1 { return isSingleWordStutter(tokens, at: start, previous: previous, trailed: !lastTrail.isEmpty) }

        // A repeated phrase is a stutter when it starts on a function word ("we should we should"); "New York New
        // York" and "good morning good morning" are not.
        guard isFunctionWord(first[start].key), !second.allSatisfy({ $0.core.first?.isUppercase == true }) else { return false }
        // Exactly two copies. A third one, whole or partial, makes it a chain said on purpose: "go team go team go
        // team", "over and over and over again", "day by day by day".
        let end = start + 2 * length
        let continuesBefore = previous.map { sameWord($0, tokens[start + length - 1]) } ?? false
        let continuesAfter = end < tokens.count && sameWord(tokens[end], tokens[end - length])
        return !continuesBefore && !continuesAfter
    }

    /// Whether the doubled word at `index` is a stutter. Only a function word can be: a doubled content word is
    /// reduplication or emphasis ("boo boo", "far far away", "Night night") however it is cased.
    private static func isSingleWordStutter(_ tokens: [Token], at index: Int, previous: Token?, trailed: Bool) -> Bool {
        let key = normalizedKey(tokens[index])
        if !trailed, legitimateDoubles.contains(key) { return false }
        // "The The" is a name; only the pronoun is capitalized wherever it stands.
        let isPronounI = key == "i" || key.hasPrefix("i'")
        if tokens[index + 1].core.first?.isUppercase == true, !isPronounI { return false }
        if stutterWords.contains(key) { return true }
        guard auxiliaryWords.contains(key), let previous else { return false }
        return previous.isWord && previous.trail.isEmpty && personalPronouns.contains(normalizedKey(previous))
    }

    private static func sameWord(_ a: Token, _ b: Token) -> Bool {
        a.isWord && b.isWord && a.key == b.key
    }

    private static func isFunctionWord(_ key: String) -> Bool {
        functionWords.contains(key.replacingOccurrences(of: "\u{2019}", with: "'"))
    }

    /// "w-w-we" and "w-we" become "we"; anything that is not a stuttered first letter is left alone.
    private static func repairLetterStutter(_ core: String) -> String? {
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let word = parts.last, word.count >= 2, let letter = word.first, letter.isLetter else { return nil }
        let stutters = parts.dropLast()
        guard stutters.allSatisfy({ $0.count == 1 && $0.lowercased() == letter.lowercased() }) else { return nil }
        // With one fragment the word must be one people stutter on; this keeps "t-test", "D-Day" and "e-mail" whole.
        guard parts.count >= 3 || isFunctionWord(word.lowercased()) else { return nil }
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

    private static func normalizedKey(_ token: Token) -> String {
        token.key.replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static let iContractions: Set<String> = ["i'm", "i'll", "i've", "i'd"]
    /// What follows the pronoun "i": an auxiliary, a common verb or an adverb. A variable is followed by "as", "in",
    /// "to", "plus", "equals" and the like, so those are not here.
    private static let pronounFollowers: Set<String> = [
        "am", "was", "were", "have", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "do", "did", "think", "thought", "guess", "suppose", "believe", "know", "knew", "see", "saw", "say", "said",
        "mean", "meant", "feel", "felt", "want", "need", "like", "love", "hate", "hope", "wish", "wonder", "remember",
        "forget", "forgot", "understand", "realize", "realise", "assume", "agree", "appreciate", "apologize",
        "apologise", "promise", "get", "got", "go", "went", "give", "gave", "take", "took", "make", "made", "try",
        "find", "found", "tell", "told", "ask", "hear", "heard", "read", "wrote", "write", "sent", "send", "left",
        "leave", "came", "come", "look", "miss", "prefer", "expect", "use", "work", "live", "run", "ran", "call",
        "bought", "buy", "put", "thank", "really", "just", "also", "always", "never", "still", "probably", "actually",
        "definitely", "usually", "often", "already", "even", "only", "now", "mostly", "totally", "honestly",
        "basically", "generally", "personally", "currently", "recently", "finally", "simply", "certainly",
        "obviously", "sometimes", "rarely",
    ]
    /// Before a variable: "use i", "of i", "index i". The pronoun never follows a determiner or preposition.
    private static let beforeVariable: Set<String> = [
        "use", "using", "let", "var", "int", "set", "increment", "decrement", "loop", "variable", "index", "named",
        "letter", "counter", "iterator", "the", "a", "an", "of", "for", "to", "in", "on", "at", "by", "with", "from",
        "into", "over", "per", "between",
    ]
    /// Auxiliaries and comparisons that put the pronoun right behind them: "so do i", "can i", "than i".
    private static let beforePronoun: Set<String> = [
        "so", "neither", "nor", "than", "as", "am", "do", "does", "did", "can", "could", "will", "would", "should",
        "shall", "may", "might", "must", "have", "has", "had",
    ]

    /// Capitalizes the pronoun "i" and its contractions. A lone "i" that is a variable or an index ("use i as the
    /// index", "set i to zero") is left as written.
    private func fixPronounI(_ tokens: inout [Token]) {
        for index in tokens.indices where tokens[index].isWord {
            let core = tokens[index].core
            let key = Self.normalizedKey(tokens[index])
            guard core == core.lowercased(), !protectedSpellings.contains(core) else { continue }
            if Self.iContractions.contains(key) {
                tokens[index].core = Self.capitalizingFirst(core)
            } else if key == "i", Self.isPronoun(tokens, at: index) {
                tokens[index].core = "I"
            }
        }
    }

    /// What follows a variable named i: "i plus one", "i is less than ten", "i goes from 0 to 9".
    private static let variableFollowers: Set<String> = [
        "as", "in", "to", "from", "through", "till", "plus", "minus", "times", "over", "modulo", "mod", "equals",
        "equal", "is", "less", "greater", "smaller", "bigger", "larger", "by", "at", "of", "on", "squared", "goes",
        "starts", "runs", "ranges", "counts", "increments", "iterates", "points", "refers", "represents", "holds",
        "stores", "and", "or",
    ]
    /// Words after which a new clause, and so a subject, can begin: "and i ate", "when i misplace".
    private static let clauseOpeners: Set<String> = [
        "and", "but", "so", "or", "if", "when", "while", "because", "that", "then", "maybe", "perhaps", "since", "though",
        "although", "unless", "until", "once", "whether", "where", "what", "how", "why", "who", "after", "before",
    ]

    private static func isPronoun(_ tokens: [Token], at index: Int) -> Bool {
        let before = index > 0 ? tokens[index - 1] : nil
        let previous = before?.isWord == true && before?.trail.isEmpty == true ? before.map(normalizedKey) : nil
        if let previous, beforePronoun.contains(previous) { return true }
        if let previous, beforeVariable.contains(previous) { return false }
        guard tokens[index].trail.isEmpty, index + 1 < tokens.count, tokens[index + 1].isWord else { return false }
        let next = normalizedKey(tokens[index + 1])
        if pronounFollowers.contains(next) || next.hasSuffix("n't") || next.hasSuffix("ed") || next.hasSuffix("ly") { return true }
        // Any other word: the pronoun only where a subject can stand, which is the start of a clause.
        guard next.first?.isLetter == true, !variableFollowers.contains(next) else { return false }
        return previous == nil || clauseOpeners.contains(previous ?? "")
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
            if atStart, Self.isPlainLowercase(core), !protectedSpellings.contains(core),
                !Self.startsCommand(tokens, at: index)
            {
                tokens[index].core = Self.capitalizingFirst(core)
            }
            let abbreviation = Self.abbreviations.contains(tokens[index].key) || core.contains(".")
            let trail = tokens[index].trail
            // "Well... maybe" trails off and carries on; it does not start a new sentence.
            let trailsOff = trail.contains("...") || trail.contains("\u{2026}")
            atStart = trail.contains(where: { $0 == "!" || $0 == "?" }) || (Self.endsSentence(trail) && !abbreviation && !trailsOff)
        }
    }

    // MARK: - Closing punctuation

    /// Command-line tools that are dictated as the first word of a command: "git rebase main branch".
    private static let commandNames: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "kubectl", "docker", "helm", "terraform", "ls", "cd", "pwd", "mkdir",
        "rmdir", "chmod", "chown", "grep", "curl", "wget", "ssh", "scp", "sudo", "brew", "pip", "pip3", "cargo",
        "rustc", "swift", "xcodebuild", "tmux", "vim",
    ]
    /// What follows a command name when the word is just a word: "swift is fast".
    private static let afterNameWord: Set<String> = [
        "is", "are", "was", "were", "has", "have", "had", "does", "did", "will", "would", "can", "could", "should", "may",
        "might", "must", "means", "isn't", "doesn't", "wasn't", "won't",
    ]

    /// Whether the word at `index` is a command-line tool opening a command ("git rebase", not "git is a tool").
    private static func startsCommand(_ tokens: [Token], at index: Int) -> Bool {
        guard commandNames.contains(tokens[index].key) else { return false }
        let second = index + 1 < tokens.count ? tokens[index + 1] : nil
        return second?.isWord != true || !afterNameWord.contains(second?.key ?? "")
    }

    /// Whether the sentence reads as something typed into a terminal rather than prose.
    private static func looksLikeCommand(_ tokens: [Token], from start: Int, through end: Int) -> Bool {
        if startsCommand(tokens, at: start) { return true }
        return tokens[start...end].contains { token in
            let core = Array(token.core)
            return core.count > 1 && core[0] == "-" && (core[1].isLetter || core[1] == "-")
        }
    }

    private static let invertingAuxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "does", "did", "will", "would", "can", "could", "should", "shall", "may",
        "might", "must", "has",
    ]
    /// "do", "have" and "had" also start commands ("do this", "have it done"), so only a person counts as a subject.
    private static let imperativeAuxiliaries: Set<String> = ["do", "have", "had"]
    private static let personSubjects: Set<String> = [
        "i", "you", "we", "they", "anyone", "anybody", "someone", "somebody", "everyone", "everybody",
    ]
    private static let otherSubjects: Set<String> = [
        "he", "she", "it", "there", "this", "that", "these", "those", "nobody", "the", "a", "an", "my", "your", "our",
        "their", "his", "her", "its", "any", "some", "every", "each",
    ]
    private static let whWords: Set<String> = ["what", "who", "whom", "whose", "where", "when", "why", "how"]
    private static let whContractions: Set<String> = [
        "what's", "who's", "where's", "when's", "why's", "how's", "what're", "who're", "where're", "how're",
    ]
    /// "how many ounces are in a pound", "how about lunch"; "how to fix it" and "how I did it" are statements.
    private static let howQuestionWords: Set<String> = [
        "many", "much", "long", "old", "far", "often", "big", "tall", "fast", "soon", "come", "about",
    ]
    private static let questionNouns: Set<String> = [
        "time", "day", "date", "month", "year", "week", "size", "color", "colour", "kind", "type", "sort", "one", "ones",
        "version", "option", "else",
    ]

    /// Whether the sentence is plainly a question without punctuation to say so: one clause that opens with an
    /// inverted auxiliary and its subject ("can you send it") or a wh-word and an auxiliary ("what is the plan").
    private static func isPlainQuestion(_ sentence: ArraySlice<Token>) -> Bool {
        guard sentence.dropLast().allSatisfy({ $0.trail.isEmpty }) else { return false }
        let keys = sentence.map(normalizedKey)
        guard let first = keys.first else { return false }
        let second = keys.count > 1 ? keys[1] : ""
        if invertingAuxiliaries.contains(first) {
            return personSubjects.contains(second) || otherSubjects.contains(second)
        }
        if imperativeAuxiliaries.contains(first) { return personSubjects.contains(second) }
        if whContractions.contains(first) { return true }
        if whWords.contains(first) {
            if invertingAuxiliaries.contains(second) || imperativeAuxiliaries.contains(second) { return true }
            if first == "how", howQuestionWords.contains(second) { return true }
        }
        // "which" opens statements too ("which is why we left"); it asks only before a noun ("which one").
        return (first == "what" || first == "which") && questionNouns.contains(second)
    }

    /// Text that arrived uncased (lowercase, no punctuation) gets a closing mark when it reads as a sentence:
    /// "?" if it is plainly a question, otherwise ".". Commands typed at a terminal are left without one.
    private func closeFinalSentence(_ tokens: inout [Token]) {
        guard tokens.filter(\.isWord).count >= 3, let lastIndex = tokens.lastIndex(where: \.isWord) else { return }
        let last = tokens[lastIndex]
        guard last.trail.isEmpty, last.core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" }) else { return }

        var first = lastIndex
        while first > 0, tokens[first - 1].isWord, !Self.endsSentence(tokens[first - 1].trail) { first -= 1 }
        guard !Self.looksLikeCommand(tokens, from: first, through: lastIndex) else { return }
        tokens[lastIndex].trail = Self.isPlainQuestion(tokens[first...lastIndex]) ? "?" : "."
    }
}
