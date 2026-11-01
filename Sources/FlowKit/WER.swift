import Foundation

/// Word error rate scoring.
public enum WER {
    /// Lowercase, drop punctuation (keeping apostrophes and hyphens inside words), split on whitespace.
    /// Numbers are not normalised, so "20" and "twenty" count as different words.
    public static func tokens(_ text: String) -> [String] {
        words(text).map(\.text)
    }

    /// One word of a text with the layout around it, which `CleanupGuard` uses to tell a spoken
    /// correction ("on Tuesday, no, Wednesday") from an ordinary "no".
    struct Word: Equatable, Sendable {
        /// Lowercased, as `tokens` returns it.
        var text: String
        /// A comma, semicolon, colon or dash separated this word from the one before.
        var afterComma = false
        /// The first letter was uppercase in the text.
        var capitalized = false
        /// First word of the text, or follows . ! ? or a line break.
        var startsSentence = false
        /// Written with a trailing hyphen ("th-" in "th- the"), the mark of a stutter fragment.
        var hyphenAfter = false
    }

    /// The words `tokens` finds, with their layout. With `numberAware`, "3:30", "2,500" and "2.4.1" stay whole
    /// instead of splitting at their punctuation, "15%" gains a following "percent" and "$49" a following "dollars",
    /// so a spoken and a written form of the same amount have the same words.
    static func words(_ text: String, numberAware: Bool = false) -> [Word] {
        var lowered: [Unicode.Scalar] = []
        var uppercase: [Bool] = []
        lowered.reserveCapacity(text.unicodeScalars.count)
        uppercase.reserveCapacity(lowered.capacity)
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                let isUpper = scalar.value >= 65 && scalar.value <= 90
                lowered.append(isUpper ? Unicode.Scalar(scalar.value + 32)! : scalar)
                uppercase.append(isUpper)
                continue
            }
            let isUpper = scalar.properties.isUppercase
            for mapped in scalar.properties.lowercaseMapping.unicodeScalars {
                lowered.append(mapped == "\u{2019}" ? "'" : mapped)
                uppercase.append(isUpper)
            }
        }

        var result: [Word] = []
        var token = String.UnicodeScalarView()
        var tokenCapitalized = false
        var tokenAfterComma = false
        var tokenStartsSentence = false
        var pendingComma = false
        var pendingSentence = true
        var pendingCurrency: String?
        var endsSentence = false
        let trimmed = CharacterSet(charactersIn: "'-")

        func finishToken() {
            guard !token.isEmpty else { return }
            let raw = String(token)
            token = String.UnicodeScalarView()
            let text = raw.trimmingCharacters(in: trimmed)
            if text.isEmpty {
                // Nothing but quote marks or hyphens: leave the layout marks for the next word.
                pendingComma = pendingComma || tokenAfterComma
                pendingSentence = pendingSentence || tokenStartsSentence
                return
            }
            result.append(
                Word(
                    text: text, afterComma: tokenAfterComma, capitalized: tokenCapitalized, startsSentence: tokenStartsSentence,
                    hyphenAfter: raw.hasSuffix("-")))
            if numberAware, let currency = pendingCurrency, isDigit(text.unicodeScalars.first!) {
                result.append(Word(text: currency))
            }
            pendingCurrency = nil
        }

        for index in lowered.indices {
            let scalar = lowered[index]
            let previous = index > 0 ? lowered[index - 1] : " "
            let next = index + 1 < lowered.count ? lowered[index + 1] : " "
            let isWordScalar =
                scalar.isASCII
                ? ((scalar.value >= 97 && scalar.value <= 122) || isDigit(scalar) || scalar == "'" || scalar == "-")
                : CharacterSet.alphanumerics.contains(scalar)
            var joins = false
            if scalar == "." && CharacterSet.letters.contains(previous) {
                // "p.m." and "i.d." are one word, not several. A dot that ends the word still ends a sentence,
                // unless it closes such an abbreviation.
                if !CharacterSet.letters.contains(next), !(index > 1 && lowered[index - 2] == ".") { endsSentence = true }
                continue
            }
            if numberAware, scalar == "." || scalar == "," || scalar == ":", isDigit(previous), isDigit(next), !token.isEmpty {
                joins = true
            }
            if isWordScalar || joins {
                if token.isEmpty {
                    tokenCapitalized = uppercase[index]
                    tokenAfterComma = pendingComma
                    tokenStartsSentence = pendingSentence
                    pendingComma = false
                    pendingSentence = false
                }
                token.append(scalar)
                continue
            }
            finishToken()
            if endsSentence {
                pendingSentence = true
                endsSentence = false
            }
            switch scalar {
            case ",", ";", ":", "\u{2014}", "\u{2013}": pendingComma = true
            case ".", "!", "?", "\u{2026}", "\n", "\r": pendingSentence = true
            case "%" where numberAware:
                if let last = result.last, isDigit(last.text.unicodeScalars.first!) { result.append(Word(text: "percent")) }
            case "$" where numberAware: pendingCurrency = "dollars"
            case "\u{20AC}" where numberAware: pendingCurrency = "euros"
            case "\u{00A3}" where numberAware: pendingCurrency = "pounds"
            default: break
            }
        }
        finishToken()
        return result
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }

    /// Word-level edit distance divided by reference length. An empty reference scores 0 when
    /// the hypothesis is also empty, otherwise 1.
    public static func rate(reference: String, hypothesis: String) -> Double {
        let ref = tokens(reference)
        let hyp = tokens(hypothesis)
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Percentile (0...1) using nearest-rank on a sorted copy.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }
}
