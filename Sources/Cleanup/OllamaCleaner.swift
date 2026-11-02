import FlowKit
import Foundation

/// Cleanup with a local Ollama model through `POST /api/chat`.
public final class OllamaCleaner: TextCleaner, Sendable {
    public let name: String
    private let model: String
    private let baseURL: URL
    private let keepAlive: String
    private let session: URLSession

    /// Same on every request: Ollama reloads the model when the context size changes.
    static let contextTokens = 4096

    /// - Parameters:
    ///   - model: an installed Ollama tag such as `gemma3:4b`.
    ///   - keepAlive: how long the server keeps the model in memory after a request.
    public init(model: String, baseURL: URL = URL(string: "http://localhost:11434")!, keepAlive: String = "30m") {
        self.model = model
        self.name = "ollama:\(model)"
        self.baseURL = baseURL
        self.keepAlive = keepAlive
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    /// Checks the server is up and has the model, then loads it so the first real call is fast.
    public func prepare() async throws {
        let (data, _) = try await send(URLRequest(url: baseURL.appendingPathComponent("api/tags")))
        let installed = (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
        let wanted = model.contains(":") ? [model] : [model, "\(model):latest"]
        guard installed.contains(where: wanted.contains) else {
            let list = installed.isEmpty ? "none" : installed.sorted().joined(separator: ", ")
            throw CleanupError.unavailable("model \(model) is not installed in Ollama (installed: \(list)); try `ollama pull \(model)`")
        }
        // An empty chat request loads the model without generating anything.
        _ = try await post(path: "api/chat", body: Self.encode(Load(model: model, keepAlive: keepAlive)))
    }

    public func clean(_ raw: String) async throws -> String {
        let chunks = TextChunker.split(raw, maxCharacters: CleanupPrompt.maxChunkCharacters)
        var cleaned: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()  // stop early when the pipeline has given up
            cleaned.append(try await cleanChunk(chunk.text))
        }
        return CleanupPrompt.join(cleaned, separators: chunks.map(\.separator))
    }

    private func cleanChunk(_ text: String) async throws -> String {
        let body = try Self.requestBody(model: model, text: text, keepAlive: keepAlive)
        let data = try await post(path: "api/chat", body: body)
        let content = try Self.parseReply(data)
        let output = CleanupPrompt.extractOutput(from: content, original: text)
        guard !output.isEmpty else { throw CleanupError.emptyResponse }
        return output
    }

    // MARK: - Wire format

    private struct Tags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct Load: Encodable {
        let model: String
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model
            case keepAlive = "keep_alive"
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct Options: Encodable {
        let temperature: Double
        let maxTokens: Int
        let contextTokens: Int
        let seed: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxTokens = "num_predict"
            case contextTokens = "num_ctx"
            case seed
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let think: Bool
        let keepAlive: String
        let options: Options

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, think, options
            case keepAlive = "keep_alive"
        }
    }

    private struct ChatReply: Decodable {
        let message: Message?
        let error: String?
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func requestBody(model: String, text: String, keepAlive: String) throws -> Data {
        try encode(
            ChatRequest(
                model: model,
                messages: [
                    Message(role: "system", content: CleanupPrompt.instructions),
                    Message(role: "user", content: CleanupPrompt.userMessage(for: text)),
                ],
                stream: false,
                think: false,
                keepAlive: keepAlive,
                options: Options(
                    temperature: 0,
                    maxTokens: CleanupPrompt.maxOutputTokens(forInput: text),
                    contextTokens: contextTokens,
                    seed: 0)))
    }

    static func parseReply(_ data: Data) throws -> String {
        guard let reply = try? JSONDecoder().decode(ChatReply.self, from: data) else {
            throw CleanupError.failed("unreadable Ollama reply")
        }
        if let error = reply.error { throw CleanupError.failed(error) }
        guard let content = reply.message?.content else { throw CleanupError.emptyResponse }
        return content
    }

    // MARK: - Transport

    private func post(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request).0
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CleanupError.failed("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(ChatReply.self, from: data))?.error
                    ?? String(data: data, encoding: .utf8) ?? ""
                throw CleanupError.failed("Ollama returned \(http.statusCode): \(message)")
            }
            return (data, http)
        } catch let error as CleanupError {
            throw error
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(error.code) {
            throw CleanupError.unavailable("Ollama is not running at \(baseURL.absoluteString)")
        } catch {
            throw CleanupError.failed(error.localizedDescription)
        }
    }
}
