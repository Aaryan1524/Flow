import Foundation

/// Spoken "take that back" commands, resolved by rule before anything else looks at the text. Instant, and
/// independent of the AI.
///
/// Two forms are understood, and nothing else:
/// - **Throw away everything so far:** "Scratch all of that", "strike all of these", "scratch everything", or
///   "You know what, scratch it". Everything said before the command in that dictation is dropped.
/// - **Throw away the last sentence:** "Scratch that." or "Strike that." as a sentence of its own removes it and the
///   sentence before it. At the very start of a dictation it just removes itself.
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
    private static let leadIn = #"(?:(?:you know what|okay|ok|so|well|alright|right|actually)\s*,?\s+){0,2}"#
    /// "scratch all of these off the list" is ordinary English, not a command.
    private static let notFollowedByAParticle = #"(?!(?:off|out|from|of|on|with|away|through|up|down|in|into|at|over)\b)"#

    private static let discardAll = regex(
        anyBoundary + leadIn
            + #"(?:scratch|strike)\s+(?:all\s+of\s+(?:that|this|these|those|it)|all\s+(?:that|this|these|those)|everything|the\s+whole\s+(?:thing|lot))\b[\s,.!?…;:]*+"#
            + notFollowedByAParticle)

    private static let discardItAfterYouKnowWhat = regex(
        anyBoundary + #"you know what\s*,?\s+(?:scratch|strike)\s+(?:it|this|these)\b[\s,.!?…;:]*+"# + notFollowedByAParticle)

    /// "Scratch that." needs punctuation (or the end of the text) after it, so "scratch that itch" is left alone.
    private static let discardLastSentence = regex(
        sentenceBoundary + leadIn + #"(?:scratch|strike)\s+that(?:\s*[.!?…,]\s*+|\s*$)"#)

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

        for pattern in [discardAll, discardItAfterYouKnowWhat] {
            if let match = pattern.matches(in: text, range: full).last {
                candidates.append(Command(start: match.range.location, end: match.range.upperBound, dropFrom: 0))
            }
        }
        if let match = discardLastSentence.matches(in: text, range: full).last {
            let boundary = match.range(at: 1)
            let cueStart = boundary.upperBound
            candidates.append(Command(start: match.range.location, end: match.range.upperBound, dropFrom: previousSentenceStart(ns, before: boundary, cueStart: cueStart)))
        }
        guard let command = candidates.max(by: { $0.start < $1.start }) else { return nil }
        let kept = ns.substring(to: command.dropFrom) + ns.substring(from: command.end)
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "vs", "etc", "jr", "sr", "inc", "ltd", "fig", "figs", "approx", "cf", "no",
    ]

    /// Start of the sentence that ends just before `boundary` (the punctuation and spaces in front of the command).
    /// Full stops after abbreviations and initials ("Dr.", "U.S.") are not sentence ends. Returns the command's own
    /// start when there is no sentence before it.
    private static func previousSentenceStart(_ ns: NSString, before boundary: NSRange, cueStart: Int) -> Int {
        guard boundary.length > 0, boundary.location > 0 else { return cueStart }
        let chars = Array(ns as String)
        // `boundary` begins with the previous sentence's own terminator, so look for the one before that.
        var index = boundary.location - 1
        while index >= 0 {
            if ".!?…".contains(chars[index]), index + 1 < chars.count, chars[index + 1].isWhitespace, isRealSentenceEnd(chars, at: index) {
                var start = index + 1
                while start < chars.count, chars[start].isWhitespace { start += 1 }
                return start
            }
            index -= 1
        }
        return 0
    }

    private static func isRealSentenceEnd(_ chars: [Character], at terminator: Int) -> Bool {
        guard chars[terminator] == "." else { return true }
        var start = terminator
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let word = String(chars[start..<terminator]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'([{"))
        if abbreviations.contains(word) { return false }
        if word.count == 1, word.first?.isLetter == true { return false }  // an initial
        if word.contains(".") { return false }  // "U.S", "e.g", "p.m"
        return true
    }
}
