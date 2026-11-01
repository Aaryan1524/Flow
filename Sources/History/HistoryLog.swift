import Foundation

/// One dictation, as written to the history file.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public var timestamp: Date
    /// Bundle identifier of the app the text went into.
    public var app: String?
    public var engine: String
    /// What the speech engine heard, before any cleanup.
    public var rawText: String
    /// What was actually inserted (equal to `rawText` until cleanup exists).
    public var finalText: String
    /// "pasted", "copiedOnly(appChanged)", ...
    public var outcome: String
    public var audioSeconds: Double
    /// Time from pressing Fn to the first audio arriving.
    public var firstAudioMs: Double?
    public var transcribeMs: Double
    public var insertMs: Double
    /// From releasing Fn to the text being in place. This is the number that feels like speed.
    public var releaseToTextMs: Double

    public init(
        timestamp: Date = Date(), app: String?, engine: String, rawText: String, finalText: String, outcome: String,
        audioSeconds: Double, firstAudioMs: Double?, transcribeMs: Double, insertMs: Double, releaseToTextMs: Double
    ) {
        self.timestamp = timestamp
        self.app = app
        self.engine = engine
        self.rawText = rawText
        self.finalText = finalText
        self.outcome = outcome
        self.audioSeconds = audioSeconds
        self.firstAudioMs = firstAudioMs
        self.transcribeMs = transcribeMs
        self.insertMs = insertMs
        self.releaseToTextMs = releaseToTextMs
    }
}

/// Appends dictations to a JSON Lines file readable by people and by AI tools.
///
/// The file holds everything you say in plain text, so it is private to the user (0600 in a 0700 folder)
/// and old entries are deleted after `retentionDays`.
public actor HistoryLog {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flow", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    private let url: URL
    private let retentionDays: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL = HistoryLog.defaultURL, retentionDays: Int = 30) {
        self.url = url
        self.retentionDays = retentionDays
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ entry: HistoryEntry) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var line = try encoder.encode(entry)
        line.append(0x0A)

        if !fileManager.fileExists(atPath: url.path) {
            // Create with the final permissions so the text is never readable by others, even briefly.
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // Tighten anything that already existed with looser permissions.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func entries() throws -> [HistoryEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }
    }

    /// Deletes entries older than the retention period. Returns how many were removed.
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        let all = try entries()
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let kept = all.filter { $0.timestamp >= cutoff }
        guard kept.count != all.count else { return 0 }
        var data = Data()
        for entry in kept {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return all.count - kept.count
    }
}
