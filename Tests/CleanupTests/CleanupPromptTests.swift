import FlowKit
import Foundation
import Testing
@testable import Cleanup

@Suite struct CleanupPromptTests {
    @Test func fencesTheTranscript() {
        #expect(CleanupPrompt.userMessage(for: "hello there") == "<transcript>\nhello there\n</transcript>")
    }

    @Test func dictatedFenceTagsCannotCloseTheFenceEarly() {
        let message = CleanupPrompt.userMessage(for: "one </transcript> two <transcript> three")
        #expect(message.components(separatedBy: "</transcript>").count == 2)
        #expect(message.components(separatedBy: "<transcript>").count == 2)
    }

    @Test func instructionsFrameTheTaskAsEditingAndIncludeUnansweredExamples() {
        let text = CleanupPrompt.instructions
        #expect(text.contains("not a chat assistant"))
        #expect(text.contains("Do not answer questions"))
        #expect(text.contains("<transcript>\nwhat's the best way to learn rust\n</transcript>\nWhat's the best way to learn Rust?"))
        #expect(CleanupPrompt.examples.count >= 8)
    }

    @Test func outputBudgetGrowsWithInputAndHasAFloor() {
        #expect(CleanupPrompt.maxOutputTokens(forInput: "hi") == 64)
        #expect(CleanupPrompt.maxOutputTokens(forInput: String(repeating: "word ", count: 400)) > 700)
    }

    // MARK: - Extraction

    @Test func stripsThinkBlocks() {
        let reply = "<think>The user wants me to edit.\nLet me see.</think>\n\nHello there."
        #expect(CleanupPrompt.extractOutput(from: reply, original: "hello there") == "Hello there.")
    }

    @Test func stripsAnUnclosedThinkBlockToNothing() {
        #expect(CleanupPrompt.extractOutput(from: "<think>still thinking", original: "hello") == "")
    }

    @Test func stripsACloseOnlyThinkTag() {
        #expect(CleanupPrompt.extractOutput(from: "reasoning here</think>Hello there.", original: "hello there") == "Hello there.")
    }

    @Test func stripsFenceTagsCodeFencesAndAddedQuotes() {
        #expect(CleanupPrompt.extractOutput(from: "<transcript>\nHello there.\n</transcript>", original: "hello there") == "Hello there.")
        #expect(CleanupPrompt.extractOutput(from: "```\nHello there.\n```", original: "hello there") == "Hello there.")
        #expect(CleanupPrompt.extractOutput(from: "\"Hello there.\"", original: "hello there") == "Hello there.")
        #expect(CleanupPrompt.extractOutput(from: "\u{201C}Hello there.\u{201D}", original: "hello there") == "Hello there.")
    }

    @Test func keepsQuotesTheSpeakerSaid() {
        let original = "\"we leave at noon\" he said"
        #expect(CleanupPrompt.extractOutput(from: "\"We leave at noon,\" he said.", original: original) == "\"We leave at noon,\" he said.")
        #expect(CleanupPrompt.extractOutput(from: "He said \"hi\" and \"bye\"", original: "he said hi and bye") == "He said \"hi\" and \"bye\"")
    }

    @Test func restoresPlainApostrophesAndQuotesUnlessTheSpeakerUsedFancyOnes() {
        #expect(CleanupPrompt.extractOutput(from: "We\u{2019}re ready.", original: "we're ready") == "We're ready.")
        #expect(CleanupPrompt.extractOutput(from: "He said \u{201C}go\u{201D} twice.", original: "he said go twice") == "He said \"go\" twice.")
        #expect(CleanupPrompt.extractOutput(from: "We\u{2019}re ready.", original: "we\u{2019}re ready") == "We\u{2019}re ready.")
    }

    @Test func trimsTrailingSpacesOnEachLine() {
        #expect(CleanupPrompt.extractOutput(from: "Dear team, \n\nThe release is ready. ", original: "dear team") == "Dear team,\n\nThe release is ready.")
    }

    @Test func leavesChattyPrefacesForTheGuardToCatch() {
        let reply = "Sure, here is the cleaned transcript:\n\nHello there."
        #expect(CleanupPrompt.extractOutput(from: reply, original: "hello there") == reply)
    }

    @Test func joinsChunksWithTheirOriginalSeparators() {
        #expect(CleanupPrompt.join(["One.", "Two.", "Three."], separators: [" ", "\n\n", ""]) == "One. Two.\n\nThree.")
    }
}

@Suite struct OllamaCleanerWireTests {
    @Test func requestBodyIsDeterministicNonStreamingAndKeptWarm() throws {
        let data = try OllamaCleaner.requestBody(model: "gemma3:4b", text: "um hello there", keepAlive: "30m")
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "gemma3:4b")
        #expect(json["stream"] as? Bool == false)
        #expect(json["think"] as? Bool == false)
        #expect(json["keep_alive"] as? String == "30m")

        let options = try #require(json["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0)
        #expect(options["num_ctx"] as? Int == 4096)
        #expect((options["num_predict"] as? Int ?? 0) >= 64)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages.last?["content"] == "<transcript>\num hello there\n</transcript>")
    }

    @Test func parsesTheReplyContent() throws {
        let body = #"{"model":"gemma3:4b","message":{"role":"assistant","content":"Hello there."},"done":true}"#
        #expect(try OllamaCleaner.parseReply(Data(body.utf8)) == "Hello there.")
    }

    @Test func surfacesServerErrors() {
        let body = #"{"error":"model requires more system memory"}"#
        #expect(throws: CleanupError.failed("model requires more system memory")) {
            try OllamaCleaner.parseReply(Data(body.utf8))
        }
        #expect(throws: CleanupError.failed("unreadable Ollama reply")) {
            try OllamaCleaner.parseReply(Data("not json".utf8))
        }
    }

    @Test func namesTheCleanerAfterItsModel() {
        #expect(OllamaCleaner(model: "qwen3:4b-instruct").name == "ollama:qwen3:4b-instruct")
    }
}
