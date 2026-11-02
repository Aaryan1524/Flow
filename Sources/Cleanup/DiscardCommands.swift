import Foundation

/// Spoken "take that back" commands, resolved by rule before anything else looks at the text. Instant, and
/// independent of the AI.
///
/// - **Throw away everything so far:** "Scratch all of that", "strike all of these", "scratch everything".
/// - **Throw away the thought:** "Scratch that." as a sentence of its own, or "you know what, scratch this" anywhere,
///   even straight after a cut-off word ("One PM, two p you know what, scratch this."). It takes back the sentence
///   it follows, and reaches further back if what comes next repeats an earlier sentence.
///
/// The verbs are limited to scratch and strike on purpose. "Forget", "ignore" and "disregard" are things people
/// really dictate into AI prompts ("ignore everything above and...") and must never delete anything.
enum DiscardCommands {
    static func apply(_ text: String) -> String {
        var current = text
        // Several commands in one dictation: the last one is resolved first, then the rest.
        for _ in 0..<8 {
            guard let next = applyLast(to: current) else { break }
            current = next
        }
        return current
    }

    // MARK: - Patterns

    /// Where a command may start: the beginning, or just after a sentence or clause break.
    private static let anyBoundary = #"(^|[.!?…]\s+|[,;:]\s+)"#
    private static let sentenceBoundary = #"(^|[.!?…]\s+)"#
    /// The things people say on the way into a retraction: "I mean, you know, just scratch that".
    private static let leadIn = #"(?:(?:i mean|you know what|you know|just|okay|ok|so|well|alright|right|actually|like|yeah|um|uh|hmm|then)\s*,?\s+){0,5}"#
    /// A pivot strong enough to count anywhere, even with no punctuation before it.
    private static let pivot = #"\byou know what\s*,?\s+"#
    private static let verb = #"(?:scratch|strike)\s+"#
    private static let everything = #"(?:all\s+of\s+(?:that|this|these|those|it)|all\s+(?:that|this|these|those)|everything|the\s+whole\s+(?:thing|lot))\b[\s,.!?…;:]*+"#
    /// "scratch all of these off the list" is ordinary English, not a command.
    private static let notFollowedByAParticle = #"(?!(?:off|out|from|of|on|with|away|through|up|down|in|into|at|over)\b)"#
    /// Punctuation or the end of the text must follow, so "scratch that itch" is left alone.
    private static let closed = #"(?:\s*[.!?…,;:]\s*+|\s*$)"#

    private static let discardAll = regex(anyBoundary + leadIn + verb + everything + notFollowedByAParticle)
    private static let discardAllAfterPivot = regex(pivot + leadIn + verb + everything + notFollowedByAParticle)
    private static let discardThought = regex(sentenceBoundary + leadIn + verb + "that" + closed)
    private static let discardThoughtAfterPivot = regex(pivot + leadIn + verb + "(?:that|it|this|these)" + closed)
    private static let onlyLeadIn = regex("^" + leadIn + "$")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns above are constants, so a failure here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: - Applying the last command

    private struct Command {
        let start: Int
        let end: Int
        /// Where the text to drop begins; 0 for "everything so far".
        let dropFrom: Int
    }

    private static func applyLast(to text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [Command] = []

        for pattern in [discardAll, discardAllAfterPivot] {
            if let match = pattern.matches(in: text, range: full).last {
                candidates.append(Command(start: match.range.location, end: match.range.upperBound, dropFrom: 0))
            }
        }
        if let match = discardThought.matches(in: text, range: full).last {
            let cueStart = match.range(at: 1).upperBound
            let nearest = match.range(at: 1).length == 0 ? cueStart : previousSentenceStart(ns, before: cueStart)
            let dropFrom = reach(ns, cueStart: cueStart, cueEnd: match.range.upperBound, nearest: nearest)
            candidates.append(Command(start: match.range.location, end: match.range.upperBound, dropFrom: dropFrom))
        }
        if let match = discardThoughtAfterPivot.matches(in: text, range: full).last {
            let cueStart = match.range.location
            var nearest = sentenceStart(ns, containing: cueStart)
            // Words in front of the pivot are the cut-off thought, unless they are only "I mean" and the like.
            let fragment = ns.substring(with: NSRange(location: nearest, length: cueStart - nearest))
            let fragmentIsLeadIn = onlyLeadIn.firstMatch(in: fragment, range: NSRange(location: 0, length: (fragment as NSString).length)) != nil
            if fragmentIsLeadIn, nearest > 0 { nearest = previousSentenceStart(ns, before: nearest) }
            let dropFrom = reach(ns, cueStart: cueStart, cueEnd: match.range.upperBound, nearest: nearest)
            candidates.append(Command(start: cueStart, end: match.range.upperBound, dropFrom: dropFrom))
        }
        // The command that ends last. When two patterns found the same one, the wider match includes its lead-in.
        guard let command = candidates.max(by: { ($0.end, -$0.start) < ($1.end, -$1.start) }) else { return nil }
        let kept = ns.substring(to: min(command.dropFrom, command.start)) + ns.substring(from: command.end)
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - How far back a retraction reaches

    /// Words too common to show that two sentences are about the same thing.
    private static let commonWords: Set<String> = [
        "the", "and", "but", "for", "with", "that", "this", "these", "those", "have", "has", "had", "are", "was", "were", "will",
        "would", "should", "could", "can", "not", "you", "your", "our", "we're", "let's", "lets", "just", "about", "from", "into",
        "its", "it's", "than", "then", "there", "their", "they", "them", "what", "when", "where", "who", "how", "why", "also",
        "going", "think", "thinking", "know", "mean", "like", "okay", "yeah", "well", "guys",
    ]

    private static func contentWords(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !commonWords.contains($0) })
    }

    /// A retraction takes back `nearest` onwards. If what comes after repeats the content of an earlier recent sentence
    /// ("...the meeting tomorrow at 1pm. I don't know. Scratch that. Let's have the meeting tomorrow at 2pm."), the
    /// thought being retracted started there. At least two content words must be shared, and only the last few
    /// sentences are considered.
    private static func reach(_ ns: NSString, cueStart: Int, cueEnd: Int, nearest: Int) -> Int {
        guard nearest < cueStart, cueEnd < ns.length else { return nearest }

        // The replacement is the sentence right after the command.
        var replacementEnd = cueEnd
        while replacementEnd < ns.length, !isSentenceEnd(ns, at: replacementEnd) { replacementEnd += 1 }
        let replacement = contentWords(ns.substring(with: NSRange(location: cueEnd, length: min(replacementEnd + 1, ns.length) - cueEnd)))
        guard !replacement.isEmpty else { return nearest }

        var earliest = nearest
        var start = nearest
        var end = cueStart
        for _ in 0..<4 {
            let sentence = contentWords(ns.substring(with: NSRange(location: start, length: end - start)))
            if sentence.intersection(replacement).count >= 2 { earliest = start }
            guard start > 0 else { break }
            end = start
            start = previousSentenceStart(ns, before: start)
        }
        return earliest
    }

    // MARK: - Finding sentences

    // Positions are UTF-16 offsets throughout, the same units NSRegularExpression reports, so an emoji in the text
    // can't shift them.

    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "vs", "etc", "jr", "sr", "inc", "ltd", "fig", "figs", "approx", "cf",
    ]

    private static func isWhitespace(_ ns: NSString, at index: Int) -> Bool {
        guard let scalar = Unicode.Scalar(ns.character(at: index)) else { return false }
        return scalar.properties.isWhitespace
    }

    /// A terminator that really ends a sentence: not the full stop of "Dr.", "U.S." or "p.m.". A terminator directly
    /// followed by more text ("3.5", "main.swift") doesn't end one either.
    private static func isSentenceEnd(_ ns: NSString, at index: Int) -> Bool {
        let unit = ns.character(at: index)
        guard unit == 0x2E || unit == 0x21 || unit == 0x3F || unit == 0x2026 else { return false }
        if index + 1 < ns.length, !isWhitespace(ns, at: index + 1) { return false }
        guard unit == 0x2E else { return true }
        var start = index
        while start > 0, !isWhitespace(ns, at: start - 1) { start -= 1 }
        let word = ns.substring(with: NSRange(location: start, length: index - start)).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'([{"))
        if abbreviations.contains(word) { return false }
        if word.count == 1, word.first?.isLetter == true { return false }  // an initial
        return !word.contains(".")  // "U.S", "e.g", "p.m"
    }

    /// Start of the sentence that `index` is in.
    private static func sentenceStart(_ ns: NSString, containing index: Int) -> Int {
        var position = index - 1
        while position >= 0 {
            if isSentenceEnd(ns, at: position) {
                var start = position + 1
                while start < index, isWhitespace(ns, at: start) { start += 1 }
                return start
            }
            position -= 1
        }
        return 0
    }

    /// Start of the sentence before the one starting at `start`. Returns `start` when there isn't one.
    private static func previousSentenceStart(_ ns: NSString, before start: Int) -> Int {
        var last = start - 1
        while last >= 0, isWhitespace(ns, at: last) { last -= 1 }
        guard last >= 0 else { return start }
        return sentenceStart(ns, containing: last)
    }
}
