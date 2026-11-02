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

    @Test func joinsDottedAbbreviations() {
        #expect(WER.tokens("at 3:30 p.m. today") == ["at", "3", "30", "pm", "today"])
        #expect(WER.rate(reference: "at 3:30 PM.", hypothesis: "at 3:30 p.m.") == 0)
        // Digits keep their separating dot on both sides, so versions still compare equally
        #expect(WER.rate(reference: "version 3.2.1", hypothesis: "version 3.2.1") == 0)
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

    @Test func wordsKeepTheLayoutFactsTheGuardNeeds() {
        let words = WER.words("Dear Team, no, Wednesday morning. Next up")
        #expect(words.map(\.text) == ["dear", "team", "no", "wednesday", "morning", "next", "up"])
        #expect(words[2].afterComma)
        #expect(words[3].afterComma && !words[4].afterComma)
        #expect(words[0].capitalized && words[1].capitalized && !words[2].capitalized)
        #expect(words[0].startsSentence && words[5].startsSentence && !words[1].startsSentence)
    }

    @Test func numberAwareWordsKeepNumbersWholeAndSpellOutSymbols() {
        let text = "at 3:30 for $1,249.99 and 15% on v2.4.1"
        #expect(WER.words(text, numberAware: true).map(\.text) == ["at", "3:30", "for", "1,249.99", "dollars", "and", "15", "percent", "on", "v2.4.1"])
        // tokens() is unchanged: numbers still split on punctuation
        #expect(WER.tokens(text) == ["at", "3", "30", "for", "1", "249", "99", "and", "15", "on", "v2", "4", "1"])
        #expect(WER.words("5. Next", numberAware: true).map(\.text) == ["5", "next"])
        // speech recognisers write "3: 30" for "3:30"
        #expect(WER.words("at 3: 30 p.m.", numberAware: true).map(\.text) == ["at", "3:30", "pm"])
    }
}
