import Foundation

/// Word error rate scoring.
public enum WER {
    /// Lowercase, drop punctuation (keeping apostrophes and hyphens inside words), split on whitespace.
    /// Numbers are not normalised, so "20" and "twenty" count as different words.
    public static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var cleaned = ""
        var previous: Unicode.Scalar = " "
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "-" {
                cleaned.unicodeScalars.append(scalar)
            } else if scalar == "." && CharacterSet.letters.contains(previous) {
                // "p.m." and "i.d." are one word, not several
            } else {
                cleaned.append(" ")
            }
            previous = scalar
        }
        return cleaned
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
            .filter { !$0.isEmpty }
    }

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
