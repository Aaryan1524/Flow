import Foundation

/// Word-level difference between two versions of the same text.
public enum WordDiff {
    /// A stretch where the two versions disagree. Either side may be empty (a pure insertion or deletion).
    public struct Hunk: Sendable, Equatable {
        public let before: [String]
        public let after: [String]

        public init(before: [String], after: [String]) {
            self.before = before
            self.after = after
        }
    }

    /// The stretches that differ between `a` and `b`, in order, found with a longest common subsequence.
    public static func hunks(_ a: [String], _ b: [String]) -> [Hunk] {
        // lengths[i][j] is the length of the common subsequence of a[i...] and b[j...].
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var hunks: [Hunk] = []
        var before: [String] = []
        var after: [String] = []
        func flush() {
            if !before.isEmpty || !after.isEmpty { hunks.append(Hunk(before: before, after: after)) }
            before = []
            after = []
        }

        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lengths[i][j + 1] >= lengths[i + 1][j] {
                after.append(b[j])
                j += 1
            } else {
                before.append(a[i])
                i += 1
            }
        }
        flush()
        return hunks
    }
}
