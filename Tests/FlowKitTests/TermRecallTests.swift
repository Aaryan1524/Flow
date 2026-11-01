import Testing
@testable import FlowKit

@Suite struct TermRecallTests {
    @Test func parsesOneTermPerLine() {
        let text = "# comment\nVercel\n\n  Wispr Flow  \nvercel\nOPENAI_API_KEY\n"
        #expect(Vocabulary.parse(text) == ["Vercel", "Wispr Flow", "OPENAI_API_KEY"])
    }

    @Test func findsTermWithTrailingPunctuation() {
        #expect(TermRecall.contains("We deploy on Vercel, then test.", term: "Vercel", caseSensitive: true))
        #expect(TermRecall.contains("Is it Vercel?", term: "Vercel", caseSensitive: true))
    }

    @Test func ignoresCaseUnlessAskedNotTo() {
        #expect(TermRecall.contains("deploy on vercel", term: "Vercel", caseSensitive: false))
        #expect(!TermRecall.contains("deploy on vercel", term: "Vercel", caseSensitive: true))
    }

    @Test func matchesWholeWordsOnly() {
        #expect(!TermRecall.contains("it grows linearly", term: "Linear", caseSensitive: false))
        #expect(!TermRecall.contains("call getUserByIdentifier", term: "getUserById", caseSensitive: false))
        #expect(!TermRecall.contains("the S3 bucket", term: "S", caseSensitive: false))
        #expect(TermRecall.contains("the S3 bucket", term: "S3", caseSensitive: true))
    }

    @Test func underscoresStayInsideTheTerm() {
        #expect(TermRecall.contains("Set OPENAI_API_KEY and restart.", term: "OPENAI_API_KEY", caseSensitive: true))
        #expect(!TermRecall.contains("Set OPENAI API KEY and restart.", term: "OPENAI_API_KEY", caseSensitive: false))
        #expect(!TermRecall.contains("MY_OPENAI_API_KEY", term: "OPENAI_API_KEY", caseSensitive: false))
    }

    @Test func multiWordTerm() {
        #expect(TermRecall.contains("Wispr Flow and others", term: "Wispr Flow", caseSensitive: true))
        #expect(!TermRecall.contains("Whisperflow and others", term: "Wispr Flow", caseSensitive: false))
    }

    @Test func regexCharactersInTermsAreLiteral() {
        #expect(TermRecall.contains("use C++ here", term: "C++", caseSensitive: true))
        #expect(!TermRecall.contains("use C here", term: "C++", caseSensitive: true))
    }

    @Test func scoreCountsOnlyTermsInTheReference() {
        let terms = ["Vercel", "Supabase", "Obsidian"]
        let score = TermRecall.score(
            terms: terms,
            reference: "We deploy on Vercel and use Supabase.",
            hypothesis: "We deploy on over cell and use supabase.")
        #expect(score == TermRecall.Score(expected: 2, found: 1, foundExactCase: 0))
        #expect(score.recall == 0.5)
    }

    @Test func exactCaseIsAtMostCaseInsensitive() {
        let score = TermRecall.score(terms: ["Vercel"], reference: "Vercel", hypothesis: "Vercel")
        #expect(score == TermRecall.Score(expected: 1, found: 1, foundExactCase: 1))
    }

    @Test func zeroTermsInReferenceScoresZeroNotNaN() {
        let score = TermRecall.score(terms: ["Vercel"], reference: "nothing relevant", hypothesis: "Vercel")
        #expect(score.expected == 0)
        #expect(score.recall == 0)
        #expect(score.exactCaseRecall == 0)
    }

    @Test func scoresAddUp() {
        let a = TermRecall.Score(expected: 2, found: 1, foundExactCase: 1)
        let b = TermRecall.Score(expected: 3, found: 3, foundExactCase: 2)
        #expect(a + b == TermRecall.Score(expected: 5, found: 4, foundExactCase: 3))
    }

    @Test func termsPresentKeepsVocabularyOrder() {
        let terms = ["Notion", "Obsidian", "Linear"]
        #expect(TermRecall.termsPresent(in: "from Linear to Notion", terms: terms) == ["Notion", "Linear"])
    }
}
