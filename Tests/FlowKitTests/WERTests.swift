import Testing
@testable import FlowKit

@Suite struct WERTests {
    @Test func identicalTextScoresZero() {
        #expect(WER.rate(reference: "hello world", hypothesis: "hello world") == 0)
    }

    @Test func ignoresCaseAndPunctuation() {
        #expect(WER.rate(reference: "Hello, world!", hypothesis: "hello world") == 0)
    }

    @Test func keepsApostrophesInsideWords() {
        #expect(WER.tokens("Don't stop — it\u{2019}s fine") == ["don't", "stop", "it's", "fine"])
    }

    @Test func countsSubstitutionInsertionAndDeletion() {
        // 1 substitution over 4 reference words
        #expect(WER.rate(reference: "the cat sat down", hypothesis: "the cat sit down") == 0.25)
        // 1 insertion over 2 reference words
        #expect(WER.rate(reference: "hello world", hypothesis: "hello big world") == 0.5)
        // 2 deletions over 4 reference words
        #expect(WER.rate(reference: "a b c d", hypothesis: "a d") == 0.5)
    }

    @Test func emptyReference() {
        #expect(WER.rate(reference: "", hypothesis: "") == 0)
        #expect(WER.rate(reference: "", hypothesis: "extra") == 1)
    }

    @Test func emptyHypothesisIsTotalError() {
        #expect(WER.rate(reference: "one two three", hypothesis: "") == 1)
    }

    @Test func percentileUsesNearestRank() {
        let values = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(WER.percentile(values, 0.5) == 5)
        #expect(WER.percentile(values, 0.95) == 10)
        #expect(WER.percentile([], 0.5) == 0)
    }
}
