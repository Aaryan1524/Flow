import Foundation

/// Checks a cleanup kept what it must. Word error rate can't see these: it lowercases,
/// ignores line breaks, and a model that deletes "I think" still scores close to zero.
public enum Preservation {
    public struct Report: Sendable, Equatable {
        /// Identifiers (camelCase, snake_case, names with digits) that are missing or changed in the output.
        public let lostIdentifiers: [String]
        /// Ordinary words that disappeared although nothing in the dictation explains it. A word said
        /// twice that comes back once is listed once; a repeat the speaker stuttered is not a loss.
        public let droppedWords: [String]
        /// Numbers in the dictation, said or written, whose value is not in the output.
        public let changedNumbers: [String]

        public var isClean: Bool { lostIdentifiers.isEmpty && droppedWords.isEmpty && changedNumbers.isEmpty }
    }

    public static func check(input: String, output: String) -> Report {
        let lostIdentifiers = identifiers(in: input).filter { !output.contains($0) }

        let outputTokens = CleanupGuard.prepare(output)
        let outputWords = Set(outputTokens.filter { $0.number == nil }.map(\.text))
        let inputTokens = CleanupGuard.analyze(input, matching: outputWords)
        let expectation = CleanupGuard.expectation(from: inputTokens, cleaned: output)

        // Words are compared as a multiset, so losing one of several "the" shows up.
        var available: [String: Int] = [:]
        for token in outputTokens where token.number == nil { available[token.text, default: 0] += 1 }
        var dropped: [String] = []
        for token in expectation.outsideWords {
            if let count = available[token.text], count > 0 {
                available[token.text] = count - 1
            } else {
                dropped.append(token.text)
            }
        }

        let outputNumbers = outputTokens.reduce(into: Set<String>()) { $0.formUnion($1.number?.all ?? []) }
        let changedNumbers = expectation.outsideNumbers.filter { $0.readings.isDisjoint(with: outputNumbers) }.map(\.display)
        return Report(lostIdentifiers: lostIdentifiers, droppedWords: dropped, changedNumbers: changedNumbers)
    }

    /// Tokens that must survive character for character: internal capitals, underscores, or letters mixed with digits.
    static func identifiers(in text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let token = piece.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'`"))
            guard token.count > 1, !seen.contains(token) else { continue }
            // "Twenty-Five" and "Jean-Luc" are capitalised words, not camelCase.
            let hasInternalCapital = token.split(separator: "-").contains { part in
                part.dropFirst().contains(where: \.isUppercase) && part.contains(where: \.isLowercase)
            }
            let hasUnderscore = token.contains("_")
            // "S3" and "v2" are names; "3PM", "5th" and "3:30" are amounts.
            let mixesLettersAndDigits = token.first!.isLetter && token.contains(where: \.isLetter) && token.contains(where: \.isNumber)
            if hasInternalCapital || hasUnderscore || mixesLettersAndDigits {
                found.append(token)
                seen.insert(token)
            }
        }
        return found
    }
}

/// A number as it was said or written. Every spelling of one amount shares a reading, so "twenty five",
/// "twenty-five" and "25" agree, "two point five" meets "2.5", "three thirty" meets "3:30" and
/// "fifteen percent" meets "15%".
struct SpokenNumber: Equatable, Sendable {
    /// How the run reads in the text, for reports.
    var display: String
    /// Canonical spellings of the run taken as a whole ("2025" and "20:25" for "twenty twenty five").
    /// When the run is really a list ("five ten fifteen") these are its single numbers.
    var readings: Set<String>
    /// Readings of each word on its own, so "twenty five" also reads as 20 and 5.
    var parts: Set<String>

    var all: Set<String> { readings.union(parts) }

    // MARK: - Finding runs

    /// Maximal runs of number words and digit groups. `breaksBefore[i]` stops a run from reaching word i
    /// (a comma or sentence break), so "five, ten" stays two numbers.
    static func runs(in words: [String], breaksBefore: [Bool]) -> [(range: Range<Int>, number: SpokenNumber)] {
        var found: [(range: Range<Int>, number: SpokenNumber)] = []
        var i = 0
        while i < words.count {
            let previousIsMonth = i > 0 && months.contains(words[i - 1])
            var pieces: [Piece] = []
            if i > 0, pronounLeaders.contains(words[i - 1]), let lone = piece(words[i], ambiguousOK: false), lone.keys == ["1"],
                i + 1 == words.count || breaksBefore[i + 1] || piece(words[i + 1], ambiguousOK: false) == nil
            {
                // "each one", "no one", "which 1": the pronoun, not an amount.
                i += 1
                continue
            }
            if words[i] == "a", i + 1 < words.count, !breaksBefore[i + 1], case .scale? = piece(words[i + 1], ambiguousOK: false) {
                pieces.append(.article)
            } else if let first = piece(words[i], ambiguousOK: previousIsMonth) {
                pieces.append(first)
            } else {
                i += 1
                continue
            }
            var j = i + 1
            while j < words.count, !breaksBefore[j] {
                let word = words[j]
                let last = pieces.last!
                if let next = piece(word, ambiguousOK: last.isTens) {
                    pieces.append(next)
                    j += 1
                    continue
                }
                // Connectors only count between numbers: "one hundred and five", "two point five", "three oh five".
                guard j + 1 < words.count, !breaksBefore[j + 1], let after = piece(words[j + 1], ambiguousOK: false) else { break }
                if word == "and", last.isScale, after.isSmall {
                    pieces.append(.and)
                } else if word == "point", last.isNumeric, after.isDigitLike {
                    pieces.append(.point)
                } else if word == "oh", last.isNumeric, after.isSingleDigit {
                    pieces.append(.oh)
                } else {
                    break
                }
                j += 1
            }
            found.append((range: i..<j, number: parse(pieces, display: words[i..<j].joined(separator: " "))))
            i = j
        }
        return found
    }

    /// Words after which "one" is a pronoun ("each one", "no one", "which one") rather than the number 1.
    static let pronounLeaders: Set<String> = ["each", "every", "any", "no", "which", "whichever", "this", "that", "another", "the", "which"]

    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    // MARK: - Pieces

    enum Piece: Equatable {
        case unit(Int)  // zero...nine
        case teen(Int)  // ten...nineteen
        case tens(Int)  // twenty...ninety
        case scale(Int)  // hundred, thousand, million, billion
        case digits(Set<String>, integer: Int?)  // "25", "2.5", "3:30", "5th"
        case and, point, oh, article

        var isTens: Bool { if case .tens = self { true } else { false } }
        var isScale: Bool { if case .scale = self { true } else { false } }
        var isSmall: Bool {
            switch self {
            case .unit, .teen, .tens: true
            default: false
            }
        }
        var isNumeric: Bool {
            switch self {
            case .unit, .teen, .tens, .scale, .digits: true
            default: false
            }
        }
        var isDigitLike: Bool {
            switch self {
            case .unit, .digits: true
            default: false
            }
        }
        var isSingleDigit: Bool {
            if case .unit(let value) = self { return value > 0 }
            return false
        }

        /// Readings of this word on its own.
        var keys: Set<String> {
            switch self {
            case .unit(let value), .teen(let value), .tens(let value), .scale(let value): [String(value)]
            case .digits(let keys, _): keys
            case .and, .point, .oh, .article: []
            }
        }
    }

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000]

    /// Ordinals and the cardinal each stands for. "first" and "second" are also ordinary words
    /// ("the first option", "wait a second"), so they only count next to a month or after "twenty".
    static let ordinals: [String: String] = [
        "third": "three", "fourth": "four", "fifth": "five", "sixth": "six", "seventh": "seven", "eighth": "eight", "ninth": "nine",
        "tenth": "ten", "eleventh": "eleven", "twelfth": "twelve", "thirteenth": "thirteen", "fourteenth": "fourteen",
        "fifteenth": "fifteen", "sixteenth": "sixteen", "seventeenth": "seventeen", "eighteenth": "eighteen",
        "nineteenth": "nineteen", "twentieth": "twenty", "thirtieth": "thirty", "fortieth": "forty", "fiftieth": "fifty",
        "sixtieth": "sixty", "seventieth": "seventy", "eightieth": "eighty", "ninetieth": "ninety", "hundredth": "hundred",
        "thousandth": "thousand", "millionth": "million", "billionth": "billion",
    ]
    static let ambiguousOrdinals: [String: String] = ["first": "one", "second": "two"]

    static func piece(_ word: String, ambiguousOK: Bool) -> Piece? {
        if let first = word.unicodeScalars.first, first.value >= 48, first.value <= 57 {
            let (keys, integer) = canonicalDigits(word)
            return keys.isEmpty ? nil : .digits(keys, integer: integer)
        }
        var name = word
        if let base = ordinals[word] {
            name = base
        } else if ambiguousOK, let base = ambiguousOrdinals[word] {
            name = base
        }
        if let value = units[name] { return .unit(value) }
        if let value = teens[name] { return .teen(value) }
        if let value = tens[name] { return .tens(value) }
        if let value = scales[name] { return .scale(value) }
        return nil
    }

    /// Canonical spellings of a written number: leading zeros, thousands commas and ordinal or unit suffixes
    /// disappear ("04:00" is "4:00", "2,500" is "2500", "5th" is "5").
    static func canonicalDigits(_ token: String) -> (keys: Set<String>, integer: Int?) {
        var numeric = ""
        for scalar in token.unicodeScalars {
            if (scalar.value >= 48 && scalar.value <= 57) || scalar == "." || scalar == "," || scalar == ":" {
                numeric.unicodeScalars.append(scalar)
            } else {
                break
            }
        }
        while let last = numeric.last, !last.isNumber { numeric.removeLast() }
        guard !numeric.isEmpty else { return ([], nil) }

        func trimmedZeros(_ digits: String) -> String {
            let trimmed = digits.drop(while: { $0 == "0" })
            return trimmed.isEmpty ? "0" : String(trimmed)
        }

        if numeric.contains(":") {
            let parts = numeric.split(separator: ":").map(String.init)
            let key = ([trimmedZeros(parts[0])] + parts.dropFirst()).joined(separator: ":")
            var keys: Set<String> = [key]
            if parts.count == 2, parts[1] == "00" { keys.insert(trimmedZeros(parts[0])) }
            return (keys, nil)
        }
        if numeric.contains(",") {
            let groups = numeric.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let wholeParts = groups[0].split(separator: ",", omittingEmptySubsequences: false)
            let isThousands = wholeParts.count > 1 && wholeParts.first!.count <= 3 && wholeParts.dropFirst().allSatisfy { $0.count == 3 }
            if isThousands {
                numeric = wholeParts.joined() + (groups.count > 1 ? "." + groups[1] : "")
            } else {
                return ([numeric], nil)
            }
        }
        let dots = numeric.filter { $0 == "." }.count
        if dots == 1 {
            let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
            var fraction = String(parts[1])
            while fraction.last == "0" { fraction.removeLast() }
            let whole = trimmedZeros(String(parts[0]))
            return ([fraction.isEmpty ? whole : whole + "." + fraction], nil)
        }
        if dots > 1 { return ([numeric], nil) }
        let whole = trimmedZeros(numeric)
        return ([whole], Int(whole))
    }

    // MARK: - Reading a run

    static func parse(_ pieces: [Piece], display: String) -> SpokenNumber {
        var parts = Set<String>()
        for piece in pieces { parts.formUnion(piece.keys) }
        var readings = Set<String>()
        if pieces.count == 1 {
            readings = parts
        } else if pieces.contains(.point) {
            if let decimal = decimalReading(pieces) { readings.insert(decimal) }
        } else {
            let value = cardinal(pieces)
            if let value { readings.insert(String(value)) }
            readings.formUnion(yearAndTimeReadings(pieces))
            if let sequence = digitSequence(pieces) { readings.insert(sequence) }
            if let scaled = digitsTimesScales(pieces) { readings.insert(scaled) }
            // Words that are not one number ("five ten") are a list: any of its numbers will do.
            if value == nil { readings.formUnion(parts) }
        }
        if readings.isEmpty { readings = parts }
        return SpokenNumber(display: display, readings: readings, parts: parts)
    }

    /// "one hundred twenty three" is 123; nil when the words don't form one number.
    static func cardinal(_ pieces: [Piece]) -> Int? {
        var total = 0
        var group = 0
        var lastScale = Int.max
        var count = 0
        for piece in pieces {
            switch piece {
            case .unit(let value):
                if value == 0 { return pieces.count == 1 ? 0 : nil }
                guard group % 10 == 0, !(10...19).contains(group % 100) else { return nil }
                group += value
            case .teen(let value), .tens(let value):
                guard group % 100 == 0 else { return nil }
                group += value
            case .scale(let value):
                if value == 100 {
                    guard group < 100 else { return nil }
                    group = max(group, 1) * 100
                } else {
                    if group == 0 {
                        guard total == 0 else { return nil }
                        group = 1
                    }
                    guard value < lastScale else { return nil }
                    total += group * value
                    group = 0
                    lastScale = value
                }
            case .and, .article:
                continue
            default:
                return nil
            }
            count += 1
        }
        return count == 0 ? nil : total + group
    }

    /// "twenty twenty five" is the year 2025, "three thirty" is 3:30, "three oh five" is 3:05.
    static func yearAndTimeReadings(_ pieces: [Piece]) -> Set<String> {
        var readings = Set<String>()
        guard pieces.count >= 2 else { return readings }
        for split in 1..<pieces.count {
            let left = Array(pieces[..<split])
            var right = Array(pieces[split...])
            let hasOh = right.first == .oh
            if hasOh { right.removeFirst() }
            guard let hours = cardinal(left), let rest = cardinal(right) else { continue }
            if hasOh {
                guard (1...9).contains(rest) else { continue }
                if (10...99).contains(hours) { readings.insert(String(hours * 100 + rest)) }
                if (0...23).contains(hours) { readings.insert("\(hours):0\(rest)") }
            } else if (10...59).contains(rest) {
                if (10...99).contains(hours) { readings.insert(String(hours * 100 + rest)) }
                if (0...23).contains(hours) { readings.insert("\(hours):\(rest)") }
            } else if rest >= 60, rest <= 99, (10...99).contains(hours) {
                readings.insert(String(hours * 100 + rest))
            }
        }
        return readings
    }

    /// "one two three" read digit by digit is 123.
    static func digitSequence(_ pieces: [Piece]) -> String? {
        guard pieces.count >= 2 else { return nil }
        var digits = ""
        for piece in pieces {
            switch piece {
            case .unit(let value): digits += String(value)
            case .oh: digits += "0"
            case .digits(_, let integer?) where integer < 10: digits += String(integer)
            default: return nil
            }
        }
        return digits
    }

    /// "5 million" is 5000000.
    static func digitsTimesScales(_ pieces: [Piece]) -> String? {
        guard pieces.count >= 2, case .digits(_, let integer?) = pieces[0] else { return nil }
        var value = integer
        for piece in pieces.dropFirst() {
            guard case .scale(let scale) = piece else { return nil }
            value *= scale
        }
        return String(value)
    }

    /// "two point five" is 2.5; "two point four point one" is the version 2.4.1.
    static func decimalReading(_ pieces: [Piece]) -> String? {
        var segments: [[Piece]] = [[]]
        for piece in pieces {
            if piece == .point { segments.append([]) } else { segments[segments.count - 1].append(piece) }
        }
        func whole(_ segment: [Piece]) -> String? {
            if segment.isEmpty { return "0" }
            if case .digits(let keys, _) = segment[0], segment.count == 1 { return keys.first }
            return cardinal(segment).map(String.init)
        }
        func digitString(_ segment: [Piece]) -> String? {
            var digits = ""
            for piece in segment {
                switch piece {
                case .unit(let value): digits += String(value)
                case .oh: digits += "0"
                case .digits(_, let integer?): digits += String(integer)
                default: return nil
                }
            }
            return digits.isEmpty ? nil : digits
        }
        guard let head = whole(segments[0]) else { return nil }
        if segments.count == 2 {
            guard var fraction = digitString(segments[1]) else { return nil }
            while fraction.last == "0" { fraction.removeLast() }
            return fraction.isEmpty ? head : head + "." + fraction
        }
        var version = [head]
        for segment in segments.dropFirst() {
            guard let next = whole(segment) ?? digitString(segment) else { return nil }
            version.append(next)
        }
        return version.joined(separator: ".")
    }
}
