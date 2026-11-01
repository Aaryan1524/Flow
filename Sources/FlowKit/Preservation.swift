import Foundation

/// Checks a cleanup kept what it must. Word error rate can't see these: it lowercases,
/// ignores line breaks, and a model that deletes "I think" still scores close to zero.
public enum Preservation {
    public struct Report: Sendable, Equatable {
        /// Identifiers (camelCase, snake_case, names with digits) that are missing or changed in the output.
        public let lostIdentifiers: [String]
        /// Ordinary words that disappeared although nothing in the dictation explains it.
        public let droppedWords: [String]
        /// Numbers written with digits in the dictation that don't appear unchanged in the output.
        public let changedNumbers: [String]

        public var isClean: Bool { lostIdentifiers.isEmpty && droppedWords.isEmpty && changedNumbers.isEmpty }
    }

    /// Words a faithful cleanup removes without any correction cue.
    static let discourseWords: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "mhm", "ah", "you", "know", "like", "so", "well", "basically",
    ]

    static let spokenPunctuationWords: Set<String> = Set(CleanupGuard.spokenPunctuation.flatMap { $0 })

    public static func check(input: String, output: String) -> Report {
        let lostIdentifiers = identifiers(in: input).filter { !output.contains($0) }

        let inputWords = words(input)
        let outputWords = Set(words(output))
        let hasCue = CleanupGuard.hasCorrectionCue(inputWords, raw: input)
        var dropped: [String] = []
        var changedNumbers: [String] = []
        if !hasCue {
            let outputTokens = Set(tokens(output))
            changedNumbers = tokens(input).filter { $0.contains(where: \.isNumber) && !outputTokens.contains($0) }
            for word in inputWords where !outputWords.contains(word) && !isExpectedToChange(word) && !dropped.contains(word) {
                dropped.append(word)
            }
        }
        return Report(lostIdentifiers: lostIdentifiers, droppedWords: dropped, changedNumbers: changedNumbers)
    }

    /// Whitespace-separated pieces with surrounding punctuation removed, case kept.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`")) }
            .filter { !$0.isEmpty }
    }

    /// Tokens that must survive character for character: internal capitals, underscores, or letters mixed with digits.
    static func identifiers(in text: String) -> [String] {
        var found: [String] = []
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let token = piece.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`"))
            guard token.count > 1, !found.contains(token) else { continue }
            let hasInternalCapital = token.dropFirst().contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
            let hasUnderscore = token.contains("_")
            let hasLetter = token.contains(where: \.isLetter)
            let hasDigit = token.contains(where: \.isNumber)
            // Plain numbers and times like "3:30" are not identifiers; "S3" and "v2" are.
            let mixesLettersAndDigits = hasLetter && hasDigit && !token.allSatisfy { $0.isNumber || ":.,-/$%".contains($0) }
            if hasInternalCapital || hasUnderscore || mixesLettersAndDigits { found.append(token) }
        }
        return found
    }

    /// Lowercased words with hyphens split, so "twenty-five" and "twenty five" compare equal.
    /// A stutter fragment ("w-we") is not a word, so it is dropped.
    static func words(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        let withoutFragments = stutterFragment.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return WER.tokens(withoutFragments).flatMap { $0.split(separator: "-").map(String.init) }
    }

    /// "w-we" and "th- the": a short fragment, a hyphen, then a word that starts the same way.
    private static let stutterFragment = try! NSRegularExpression(pattern: #"\b([A-Za-z]{1,4})-\s*(?=\1)"#, options: .caseInsensitive)

    /// Fillers, numbers (which may become digits) and dictated punctuation legitimately vanish.
    static func isExpectedToChange(_ word: String) -> Bool {
        discourseWords.contains(word) || spokenPunctuationWords.contains(word) || CleanupGuard.numberWords.contains(word)
            || word.contains(where: \.isNumber)
    }
}
