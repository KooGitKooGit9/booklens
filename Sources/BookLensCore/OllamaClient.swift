import Foundation

/// Minimal client for a local Ollama server (http://localhost:11434).
public final class OllamaClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    public enum OllamaError: LocalizedError {
        case notRunning
        case http(Int, String)
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: return "Ollama 서버에 연결할 수 없습니다."
            case .http(let code, let body): return "Ollama 오류 (\(code)): \(body)"
            case .server(let message): return "Ollama 오류: \(message)"
            }
        }
    }

    public struct ModelInfo: Decodable, Equatable, Sendable {
        public var name: String
        public var size: Int64?
    }

    /// Server version, or nil if Ollama is not reachable.
    public func version() async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["version"] as? String
    }

    public func models() async throws -> [ModelInfo] {
        struct Tags: Decodable { var models: [ModelInfo] }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let data = try await send(request)
        return try JSONDecoder().decode(Tags.self, from: data).models
    }

    /// Loads a model into memory so the first real lookup is fast.
    public func warmUp(model: String) async throws {
        let body: [String: Any] = ["model": model, "messages": [] as [Any], "keep_alive": "1h"]
        var request = jsonRequest(path: "api/chat", body: body)
        request.timeoutInterval = 180
        _ = try await send(request)
    }

    /// Downloads a model, reporting progress in 0...1.
    public func pull(model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let request = jsonRequest(path: "api/pull", body: ["model": model, "stream": true])
        let (bytes, response) = try await bytesOrNotRunning(request)
        try await checkStatus(response, bytes: bytes)
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { throw OllamaError.server(error) }
            let status = obj["status"] as? String ?? ""
            if let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0,
               let completed = (obj["completed"] as? NSNumber)?.doubleValue {
                progress(completed / total, status)
            } else {
                progress(status == "success" ? 1 : 0, status)
            }
        }
    }

    public struct ChatMessage: Sendable {
        public var role: String
        public var content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Streams content chunks of a chat completion.
    public func chatStream(model: String, messages: [ChatMessage], format: [String: Any]?,
                           options: [String: Any] = [:]) -> AsyncThrowingStream<String, Error> {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "keep_alive": "1h",
            "think": false,
            "options": options,
        ]
        if let format { body["format"] = format }
        let request = jsonRequest(path: "api/chat", body: body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await bytesOrNotRunning(request)
                    try await checkStatus(response, bytes: bytes)
                    for try await line in bytes.lines {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        if let error = obj["error"] as? String { throw OllamaError.server(error) }
                        if let message = obj["message"] as? [String: Any], let content = message["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func jsonRequest(path: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.isConnectionError(error) {
            throw OllamaError.notRunning
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private func bytesOrNotRunning(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let error as URLError where Self.isConnectionError(error) {
            throw OllamaError.notRunning
        }
    }

    private func checkStatus(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        var data = Data()
        for try await b in bytes { data.append(b) }
        throw OllamaError.http(http.statusCode, Self.errorMessage(from: data))
    }

    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = obj["error"] as? String { return e }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func isConnectionError(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(error.code)
    }
}
