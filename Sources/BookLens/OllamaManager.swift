import AppKit
import BookLensCore
import Foundation

/// Tracks whether Ollama is installed/running and which models are available; can start it and pull models.
@MainActor
final class OllamaManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case notInstalled
        case notRunning
        case running(version: String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var installedModels: [String] = []
    @Published private(set) var pullProgress: [String: Double] = [:]
    @Published private(set) var pullStatus: [String: String] = [:]
    @Published var lastError: String?

    let client = OllamaClient()
    private var serveProcess: Process?
    private var warmedModel: String?

    static let binaryCandidates = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    var binaryPath: String? {
        Self.binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func hasModel(_ name: String) -> Bool {
        installedModels.contains { Self.sameModel($0, name) }
    }

    /// "qwen2.5:7b-instruct" matches "qwen2.5:7b-instruct"; a bare name matches its ":latest" tag.
    static func sameModel(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.contains(":") ? s : s + ":latest" }
        return norm(a) == norm(b)
    }

    func refresh() async {
        if let version = await client.version() {
            status = .running(version: version)
            installedModels = (try? await client.models().map(\.name)) ?? installedModels
        } else {
            installedModels = []
            status = binaryPath == nil && !FileManager.default.fileExists(atPath: "/Applications/Ollama.app") ? .notInstalled : .notRunning
        }
    }

    /// Starts the Ollama server if it is installed but not running.
    func startServer() async {
        await refresh()
        guard status == .notRunning else { return }
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"), configuration: config)
        } else if let path = binaryPath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                serveProcess = process
            } catch {
                lastError = "Ollama를 시작하지 못했습니다: \(error.localizedDescription)"
            }
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            if isRunning { return }
        }
    }

    func pull(_ model: String) async {
        guard pullProgress[model] == nil else { return }
        pullProgress[model] = 0
        pullStatus[model] = "준비 중"
        lastError = nil
        do {
            try await client.pull(model: model) { fraction, status in
                Task { @MainActor in
                    self.pullProgress[model] = fraction
                    self.pullStatus[model] = status
                }
            }
            await refresh()
        } catch {
            lastError = "\(model) 다운로드 실패: \(error.localizedDescription)"
        }
        pullProgress[model] = nil
        pullStatus[model] = nil
    }

    /// Loads the model and primes the prompt cache so the first lookup is fast.
    func warmUp(_ model: String) async {
        guard isRunning, hasModel(model), warmedModel != model else { return }
        warmedModel = model
        let provider = OllamaMeaningProvider(client: client, model: model)
        do {
            let request = LookupRequest(word: "book", sentence: "She opened the book.",
                                        dictionary: KoreanDictionary.shared.lookup("book"))
            for try await _ in provider.lookup(request) {}
        } catch {
            warmedModel = nil
        }
    }

    func stopOwnedServer() {
        serveProcess?.terminate()
        serveProcess = nil
    }
}
