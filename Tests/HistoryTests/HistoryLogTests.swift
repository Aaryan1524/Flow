import Foundation
import Testing
@testable import History

@Suite struct HistoryLogTests {
    private func makeLog(retentionDays: Int = 30) -> (HistoryLog, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-history-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.jsonl")
        return (HistoryLog(url: url, retentionDays: retentionDays), url)
    }

    private func entry(_ text: String, daysAgo: Double = 0) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date().addingTimeInterval(-daysAgo * 86_400), app: "com.apple.Notes", engine: "parakeet-v2",
            rawText: text, finalText: text, outcome: "pasted", audioSeconds: 2, firstAudioMs: 40, transcribeMs: 50,
            insertMs: 120, releaseToTextMs: 400)
    }

    @Test func appendsOneJSONObjectPerLineAndReadsThemBack() async throws {
        let (log, url) = makeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await log.append(entry("first"))
        try await log.append(entry("second"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(try await log.entries().map(\.rawText) == ["first", "second"])
    }

    @Test func fileAndFolderAreOwnerOnly() async throws {
        let (log, url) = makeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await log.append(entry("private"))
        let file = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(folder == 0o700)
    }

    @Test func pruneRemovesOnlyOldEntriesAndKeepsPermissions() async throws {
        let (log, url) = makeLog(retentionDays: 30)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await log.append(entry("old", daysAgo: 45))
        try await log.append(entry("recent", daysAgo: 2))
        #expect(try await log.prune() == 1)
        #expect(try await log.entries().map(\.rawText) == ["recent"])
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func pruneWithNothingOldLeavesTheFileAlone() async throws {
        let (log, url) = makeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await log.append(entry("recent"))
        #expect(try await log.prune() == 0)
    }

    @Test func missingFileReadsAsEmpty() async throws {
        let (log, _) = makeLog()
        #expect(try await log.entries().isEmpty)
    }

    @Test func textWithNewlinesAndQuotesStaysOnOneLine() async throws {
        let (log, url) = makeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tricky = "line one\nline \"two\"\t/path"
        try await log.append(entry(tricky))
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 1)
        #expect(try await log.entries().first?.rawText == tricky)
    }
}
