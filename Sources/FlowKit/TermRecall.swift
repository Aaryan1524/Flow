import Foundation

/// A custom vocabulary: names, products and identifiers an engine tends to get wrong.
public enum Vocabulary {
    /// One term per line. Blank lines and lines starting with `#` are ignored; repeats are dropped.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !term.hasPrefix("#"), seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }
}

/// How many vocabulary terms the engine got right. Word error rate hides this: "Vercel" heard as
/// "over cell" costs two word errors in a hundred-word clip, but it is the word the user cared about.
public enum TermRecall {
    public struct Score: Sendable, Equatable {
        /// Terms found in the reference, counted once per clip.
        public var expected = 0
        /// Of those, terms present in the hypothesis as a whole word, ignoring case.
        public var found = 0
        /// Of those, terms present with the vocabulary's own capitalisation ("Vercel", not "vercel").
        public var foundExactCase = 0

        public init(expected: Int = 0, found: Int = 0, foundExactCase: Int = 0) {
            self.expected = expected
            self.found = found
            self.foundExactCase = foundExactCase
        }

        public var recall: Double { expected == 0 ? 0 : Double(found) / Double(expected) }
        public var exactCaseRecall: Double { expected == 0 ? 0 : Double(foundExactCase) / Double(expected) }

        public static func + (a: Score, b: Score) -> Score {
            Score(expected: a.expected + b.expected, found: a.found + b.found, foundExactCase: a.foundExactCase + b.foundExactCase)
        }
    }

    /// Score one clip. Only terms that appear in the reference count.
    public static func score(terms: [String], reference: String, hypothesis: String) -> Score {
        var score = Score()
        for term in terms where contains(reference, term: term, caseSensitive: false) {
            score.expected += 1
            if contains(hypothesis, term: term, caseSensitive: false) { score.found += 1 }
            if contains(hypothesis, term: term, caseSensitive: true) { score.foundExactCase += 1 }
        }
        return score
    }

    /// Vocabulary terms that appear in `text` as whole words, ignoring case.
    public static func termsPresent(in text: String, terms: [String]) -> [String] {
        terms.filter { contains(text, term: $0, caseSensitive: false) }
    }

    /// Whole-word match. A word character is a letter, digit or underscore, so "getUserById" is not
    /// found inside "getUserByIdentifier" and "linear" is not found inside "linearly", while a
    /// trailing comma or full stop does not stop "Vercel," from matching "Vercel".
    public static func contains(_ text: String, term: String, caseSensitive: Bool) -> Bool {
        guard !term.isEmpty else { return false }
        let wordCharacter = "[\\p{L}\\p{N}_]"
        let pattern = "(?<!\(wordCharacter))\(NSRegularExpression.escapedPattern(for: term))(?!\(wordCharacter))"
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
