import Testing
@testable import Cleanup

@Suite struct TextChunkerTests {
    @Test func shortTextIsOneChunk() {
        let chunks = TextChunker.split("  Hello there. How are you?  ", maxCharacters: 100)
        #expect(chunks == [TextChunker.Chunk(text: "Hello there. How are you?", separator: "")])
    }

    @Test func emptyTextHasNoChunks() {
        #expect(TextChunker.split(" \n ", maxCharacters: 100).isEmpty)
    }

    @Test func splitsOnSentenceBoundaries() {
        let text = "The first sentence is here. The second one follows it. A third closes the paragraph."
        let chunks = TextChunker.split(text, maxCharacters: 60)
        #expect(chunks.map(\.text) == ["The first sentence is here. The second one follows it.", "A third closes the paragraph."])
        #expect(chunks.allSatisfy { $0.text.count <= 60 })
    }

    @Test func rejoiningChunksRebuildsTheText() {
        let text = "One short line. Another line follows!\n\nA new paragraph starts here? Yes it does. And ends here."
        let chunks = TextChunker.split(text, maxCharacters: 40)
        #expect(chunks.count > 1)
        let rebuilt = chunks.map { $0.text + $0.separator }.joined()
        #expect(rebuilt == text)
    }

    @Test func keepsParagraphBreaksAsSeparators() {
        let text = "First paragraph sentence one. Sentence two.\n\nSecond paragraph sentence."
        let chunks = TextChunker.split(text, maxCharacters: 45)
        #expect(chunks.first?.separator == "\n\n")
    }

    @Test func doesNotCutDecimalsOrAbbreviationsMidToken() {
        let chunks = TextChunker.split("The price is 3.5 dollars today. It was 4.25 yesterday.", maxCharacters: 35)
        #expect(chunks.map(\.text) == ["The price is 3.5 dollars today.", "It was 4.25 yesterday."])
    }

    @Test func splitsAnUnpunctuatedRunOnWords() {
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let chunks = TextChunker.split(words, maxCharacters: 50)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 50 })
        #expect(chunks.map(\.text).joined(separator: " ") == words)
    }
}
