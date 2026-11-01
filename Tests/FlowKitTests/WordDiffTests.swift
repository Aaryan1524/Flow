import Testing
@testable import FlowKit

@Suite struct WordDiffTests {
    private func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

    @Test func identicalTextHasNoHunks() {
        #expect(WordDiff.hunks(words("a b c"), words("a b c")).isEmpty)
    }

    @Test func oneWordSwapped() {
        let hunks = WordDiff.hunks(words("we use Superbase daily"), words("we use Supabase daily"))
        #expect(hunks == [WordDiff.Hunk(before: ["Superbase"], after: ["Supabase"])])
    }

    @Test func severalWordsBecomeOne() {
        let hunks = WordDiff.hunks(words("deploy on over cell now"), words("deploy on Vercel now"))
        #expect(hunks == [WordDiff.Hunk(before: ["over", "cell"], after: ["Vercel"])])
    }

    @Test func insertionAndDeletion() {
        #expect(WordDiff.hunks(words("a c"), words("a b c")) == [WordDiff.Hunk(before: [], after: ["b"])])
        #expect(WordDiff.hunks(words("a b c"), words("a c")) == [WordDiff.Hunk(before: ["b"], after: [])])
    }

    @Test func separateChangesAreSeparateHunks() {
        let hunks = WordDiff.hunks(words("a x b y c"), words("a p b q c"))
        #expect(hunks.count == 2)
        #expect(hunks[0] == WordDiff.Hunk(before: ["x"], after: ["p"]))
        #expect(hunks[1] == WordDiff.Hunk(before: ["y"], after: ["q"]))
    }

    @Test func emptySides() {
        #expect(WordDiff.hunks([], []).isEmpty)
        #expect(WordDiff.hunks([], ["a"]) == [WordDiff.Hunk(before: [], after: ["a"])])
        #expect(WordDiff.hunks(["a"], []) == [WordDiff.Hunk(before: ["a"], after: [])])
    }
}
