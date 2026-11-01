import Foundation

/// Decides whether an AI cleaner's output can be trusted as an edit of its input.
///
/// A faithful cleanup only deletes words (fillers, repeats, corrected-away phrases) and changes
/// punctuation, so the output is almost a subsequence of the input. An answer, an email, a
/// refusal or a chatty preface adds words the speaker never said, or throws most of the input
/// away. When the guard says no, callers use the deterministic rules output instead.
public struct CleanupGuard: Sendable {
    public enum Failure: Sendable, Equatable {
        /// Nothing came back although the input had words.
        case emptyOutput
        /// Far fewer words than the input: a summary, an answer, or a refusal.
        case tooShort
        /// More words than the input: added content or duplicated text.
        case tooLong
        /// Too many output words were not in the input, in order.
        case addedContent
        /// Starts or ends like a chat reply ("Sure, here is...", "I'm sorry...").
        case chattyFraming
    }

    public struct Verdict: Sendable, Equatable {
        public let failure: Failure?
        /// Output words divided by input words, ignoring um/uh style fillers.
        public let lengthRatio: Double
        /// Output words (digits aside) that do not appear in the input, in order.
        public let addedWords: Int

        public var isTrustworthy: Bool { failure == nil }
    }

    /// Floor for output/input length on short inputs; real corrections can drop a lot of a short sentence.
    public var shortInputMinRatio = 0.3
    /// Floor for long inputs, where a big drop means the model summarised or answered.
    public var longInputMinRatio = 0.55
    public var maxLengthRatio = 1.3
    /// Share of output words allowed to be new. Below 10 output words this rounds down to none.
    public var addedWordFraction = 0.1

    public init() {}

    public static let standard = CleanupGuard()

    public func isTrustworthy(raw: String, cleaned: String) -> Bool {
        evaluate(raw: raw, cleaned: cleaned).isTrustworthy
    }

    public func evaluate(raw: String, cleaned: String) -> Verdict {
        let input = WER.tokens(raw).map(Self.fold)
        let output = WER.tokens(cleaned).map(Self.fold)
        let inputWords = input.filter { !Self.fillers.contains($0) }

        if output.isEmpty {
            return Verdict(failure: inputWords.isEmpty ? nil : .emptyOutput, lengthRatio: 0, addedWords: 0)
        }
        let ratio = Double(output.count) / Double(max(1, inputWords.count))

        if Self.hasChattyFraming(input: input, output: output) {
            return Verdict(failure: .chattyFraming, lengthRatio: ratio, addedWords: 0)
        }

        // Numbers are exempt: "three thirty" becoming "3:30" is a legitimate reformat.
        let words = output.filter { !$0.contains(where: \.isNumber) }
        let aligned = Self.joinSplitWords(input, matching: Set(words))
        let added = words.count - Self.orderedMatches(words, aligned)

        var failure: Failure?
        if inputWords.count >= 4 {
            if ratio < minRatio(forInputWords: inputWords.count) {
                failure = .tooShort
            } else if ratio > maxLengthRatio {
                failure = .tooLong
            }
        }
        if failure == nil, added > Int(Double(words.count) * addedWordFraction) {
            failure = .addedContent
        }
        return Verdict(failure: failure, lengthRatio: ratio, addedWords: added)
    }

    /// Ramps from the short-input floor at 12 words to the long-input floor at 30 words.
    func minRatio(forInputWords count: Int) -> Double {
        if count <= 12 { return shortInputMinRatio }
        if count >= 30 { return longInputMinRatio }
        let t = Double(count - 12) / 18
        return shortInputMinRatio + t * (longInputMinRatio - shortInputMinRatio)
    }

    // MARK: - Matching

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "uhh", "er", "erm", "hm", "hmm", "mm", "mmm"]

    /// Lowercase tokens from `WER.tokens` with apostrophes and hyphens dropped, so "it's" meets "its".
    static func fold(_ token: String) -> String {
        token.filter { $0 != "'" && $0 != "-" }
    }

    /// Same word, allowing a plural or short suffix ("session" and "sessions").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 3 && long.count - short.count <= 3 && long.hasPrefix(short)
    }

    /// Merges runs of 2 or 3 input words into one when the output has the joined spelling,
    /// so "p m" meets "pm" and "use auth session" meets "useauthsession".
    static func joinSplitWords(_ input: [String], matching outputWords: Set<String>) -> [String] {
        var result: [String] = []
        var i = 0
        while i < input.count {
            var merged = false
            for length in [3, 2] where i + length <= input.count {
                let run = input[i..<(i + length)]
                let candidate = run.joined()
                if outputWords.contains(candidate) && !run.contains(where: outputWords.contains) {
                    result.append(candidate)
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

    /// Length of the longest common subsequence of `output` within `input`.
    static func orderedMatches(_ output: [String], _ input: [String]) -> Int {
        if output.isEmpty || input.isEmpty { return 0 }
        var previous = [Int](repeating: 0, count: input.count + 1)
        var current = previous
        for out in output {
            for (j, word) in input.enumerated() {
                current[j + 1] = sameWord(out, word) ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
        }
        return previous[input.count]
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

    static func hasChattyFraming(input: [String], output: [String]) -> Bool {
        for phrase in openers {
            let words = WER.tokens(phrase).map(fold)
            if output.starts(with: words) && !input.starts(with: words) { return true }
        }
        for phrase in closers {
            let words = WER.tokens(phrase).map(fold)
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
