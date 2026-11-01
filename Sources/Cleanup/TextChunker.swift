import Foundation

/// Splits long text into pieces a small model's context window can hold, cutting on sentence
/// boundaries (and on words only when a single sentence is too long).
public enum TextChunker {
    public struct Chunk: Sendable, Equatable {
        public let text: String
        /// The whitespace that followed this chunk in the original, so cleaned chunks can be rejoined.
        public let separator: String

        public init(text: String, separator: String) {
            self.text = text
            self.separator = separator
        }
    }

    public static func split(_ text: String, maxCharacters: Int) -> [Chunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxCharacters else { return [Chunk(text: trimmed, separator: "")] }

        var units: [Chunk] = []
        for sentence in sentences(of: trimmed) {
            if sentence.text.count <= maxCharacters {
                units.append(sentence)
            } else {
                units.append(contentsOf: splitOnWords(sentence, maxCharacters: maxCharacters))
            }
        }

        var chunks: [Chunk] = []
        var current = ""
        var currentSeparator = ""
        for unit in units {
            if current.isEmpty {
                current = unit.text
            } else if current.count + currentSeparator.count + unit.text.count <= maxCharacters {
                current += currentSeparator + unit.text
            } else {
                chunks.append(Chunk(text: current, separator: currentSeparator))
                current = unit.text
            }
            currentSeparator = unit.separator
        }
        if !current.isEmpty { chunks.append(Chunk(text: current, separator: "")) }
        return chunks
    }

    /// Sentences with the whitespace that followed each. A sentence ends at . ? ! or an ellipsis followed by
    /// whitespace, or at a line break.
    static func sentences(of text: String) -> [Chunk] {
        var result: [Chunk] = []
        var current = ""
        let characters = Array(text)
        var i = 0
        while i < characters.count {
            let character = characters[i]
            current.append(character)
            i += 1
            let endsSentence = ".?!\u{2026}".contains(character) && (i == characters.count || characters[i].isWhitespace)
            guard endsSentence || (i < characters.count && characters[i].isNewline) else { continue }

            // Pull in closing quotes or brackets, then the whitespace run.
            while i < characters.count, "\")]}\u{201D}".contains(characters[i]) {
                current.append(characters[i])
                i += 1
            }
            var separator = ""
            while i < characters.count, characters[i].isWhitespace {
                separator.append(characters[i])
                i += 1
            }
            result.append(Chunk(text: current, separator: separator))
            current = ""
        }
        if !current.isEmpty { result.append(Chunk(text: current, separator: "")) }
        return result
    }

    private static func splitOnWords(_ sentence: Chunk, maxCharacters: Int) -> [Chunk] {
        var pieces: [Chunk] = []
        var current = ""
        for word in sentence.text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maxCharacters {
                current += " " + word
            } else {
                pieces.append(Chunk(text: current, separator: " "))
                current = String(word)
            }
        }
        if !current.isEmpty { pieces.append(Chunk(text: current, separator: sentence.separator)) }
        return pieces
    }
}
