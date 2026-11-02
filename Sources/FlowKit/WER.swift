import Foundation

/// Word error rate scoring.
public enum WER {
    /// Lowercase, drop punctuation (keeping apostrophes and hyphens inside words), split on whitespace.
    /// Numbers are not normalised, so "20" and "twenty" count as different words.
    public static func tokens(_ text: String) -> [String] {
        words(text).map(\.text)
    }

    /// Punctuation and breaks between two words, so `CleanupGuard` can check that a dictated "comma" or
    /// "new paragraph" really became a symbol at that spot.
    struct Marks: OptionSet, Sendable {
        let rawValue: UInt8
        static let comma = Marks(rawValue: 1 << 0)
        static let period = Marks(rawValue: 1 << 1)
        static let question = Marks(rawValue: 1 << 2)
        static let exclamation = Marks(rawValue: 1 << 3)
        static let newline = Marks(rawValue: 1 << 4)
        /// A semicolon, colon, dash or ellipsis.
        static let other = Marks(rawValue: 1 << 5)
    }

    /// One word of a text with the layout around it, which `CleanupGuard` uses to tell a spoken
    /// correction ("on Tuesday, no, Wednesday") from an ordinary "no".
    struct Word: Equatable, Sendable {
        /// Lowercased, as `tokens` returns it.
        var text: String
        /// Two or more letters, all of them upper case in the text ("NASA").
        var allCaps = false
        /// Punctuation and line breaks between the previous word and this one.
        var marksBefore: Marks = []
        /// Added by `numberAware` for a "%" or currency sign ("percent", "dollars"); it is not written as a word.
        var synthetic = false
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
        lexed(text, numberAware: numberAware).words
    }

    /// `words`, plus the punctuation after the last word.
    static func lexed(_ text: String, numberAware: Bool = false) -> (words: [Word], trailingMarks: Marks) {
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
        var tokenLetters = 0
        var tokenUpper = 0
        var tokenCapitalized = false
        var tokenAfterComma = false
        var tokenStartsSentence = false
        var tokenMarks: Marks = []
        var pendingComma = false
        var pendingSentence = true
        var pendingMarks: Marks = []
        var pendingCurrency: String?
        var endsSentence = false
        var skipSpace = false
        let trimmed = CharacterSet(charactersIn: "'-")

        func finishToken() {
            guard !token.isEmpty else { return }
            let hyphenAfter = token.last == "-"
            let edged = hyphenAfter || token.first == "-" || token.first == "'" || token.last == "'"
            var text = String(token)
            if edged { text = text.trimmingCharacters(in: trimmed) }
            let allCaps = tokenLetters >= 2 && tokenUpper == tokenLetters
            token = String.UnicodeScalarView()
            if text.isEmpty {
                // Nothing but quote marks or hyphens: leave the layout marks for the next word.
                pendingComma = pendingComma || tokenAfterComma
                pendingSentence = pendingSentence || tokenStartsSentence
                pendingMarks.formUnion(tokenMarks)
                return
            }
            result.append(
                Word(
                    text: text, allCaps: allCaps, marksBefore: tokenMarks, afterComma: tokenAfterComma, capitalized: tokenCapitalized,
                    startsSentence: tokenStartsSentence, hyphenAfter: hyphenAfter))
            if numberAware, let currency = pendingCurrency, isDigit(text.unicodeScalars.first!) {
                result.append(Word(text: currency, synthetic: true))
            }
            pendingCurrency = nil
        }

        for index in lowered.indices {
            if skipSpace {
                skipSpace = false
                continue
            }
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
            // Speech recognisers write "3: 30" for "3:30".
            if numberAware, scalar == ":", isDigit(previous), next == " ", index + 2 < lowered.count, isDigit(lowered[index + 2]), !token.isEmpty {
                joins = true
                skipSpace = true
            }
            if isWordScalar || joins {
                if token.isEmpty {
                    tokenCapitalized = uppercase[index]
                    tokenAfterComma = pendingComma
                    tokenStartsSentence = pendingSentence
                    tokenMarks = pendingMarks
                    tokenLetters = 0
                    tokenUpper = 0
                    pendingComma = false
                    pendingSentence = false
                    pendingMarks = []
                }
                token.append(scalar)
                if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 128 && scalar.properties.isAlphabetic) {
                    tokenLetters += 1
                    if uppercase[index] { tokenUpper += 1 }
                }
                continue
            }
            finishToken()
            if endsSentence {
                pendingSentence = true
                pendingMarks.insert(.period)
                endsSentence = false
            }
            switch scalar {
            case ",":
                pendingComma = true
                pendingMarks.insert(.comma)
            case ";", ":", "\u{2014}", "\u{2013}":
                pendingComma = true
                pendingMarks.insert(.other)
            case ".":
                pendingSentence = true
                pendingMarks.insert(.period)
            case "!":
                pendingSentence = true
                pendingMarks.insert(.exclamation)
            case "?":
                pendingSentence = true
                pendingMarks.insert(.question)
            case "\u{2026}":
                pendingSentence = true
                pendingMarks.insert(.other)
            case "\n", "\r":
                pendingSentence = true
                pendingMarks.insert(.newline)
            case "%" where numberAware:
                if let last = result.last, isDigit(last.text.unicodeScalars.first!) {
                    result.append(Word(text: "percent", synthetic: true))
                }
            case "$" where numberAware: pendingCurrency = "dollars"
            case "\u{20AC}" where numberAware: pendingCurrency = "euros"
            case "\u{00A3}" where numberAware: pendingCurrency = "pounds"
            default: break
            }
        }
        finishToken()
        if endsSentence { pendingMarks.insert(.period) }
        if numberAware { movingCurrencyAfterScales(&result) }
        return (result, pendingMarks)
    }

    private static let scaleWords: Set<String> = ["hundred", "thousand", "million", "billion", "trillion"]

    /// "$10 million" reads "10 dollars million" once the sign is spelled out. Spoken, the currency comes last
    /// ("ten million dollars"), so it moves behind the scale words.
    private static func movingCurrencyAfterScales(_ words: inout [Word]) {
        var i = 0
        while i < words.count {
            guard words[i].synthetic, ["dollars", "euros", "pounds"].contains(words[i].text) else {
                i += 1
                continue
            }
            var end = i + 1
            while end < words.count, !words[end].synthetic, scaleWords.contains(words[end].text) { end += 1 }
            if end > i + 1 {
                let currency = words.remove(at: i)
                words.insert(currency, at: end - 1)
            }
            i = max(end, i + 1)
        }
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
