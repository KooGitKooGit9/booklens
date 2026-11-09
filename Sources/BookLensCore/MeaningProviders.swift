import CoreServices
import Foundation

/// Contextual definitions from a local Ollama model.
public struct OllamaMeaningProvider: MeaningProvider {
    public var client: OllamaClient
    public var model: String

    public init(client: OllamaClient = OllamaClient(), model: String) {
        self.client = client
        self.model = model
    }

    public func lookup(_ request: LookupRequest) -> AsyncThrowingStream<LookupEvent, Error> {
        let stream = client.chatStream(
            model: model,
            messages: Prompt.messages(for: request),
            format: Prompt.schema(dictionary: request.dictionary != nil),
            options: ["temperature": 0.1, "num_predict": 320, "num_ctx": 2048]
        )
        let source = "ollama:\(model)"
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                var last = WordDefinition()
                let dictionary = request.dictionary
                func parse() -> WordDefinition {
                    var def = WordDefinition.fromModelJSON(buffer, source: source)
                    def.dictionary = dictionary
                    if let dictionary {
                        def.ipa = dictionary.ipa
                        def.lemma = dictionary.headword
                    }
                    return def
                }
                do {
                    for try await chunk in stream {
                        buffer += chunk
                        let def = parse()
                        if def != last {
                            last = def
                            continuation.yield(.partial(def))
                        }
                        // A derailed model starts emitting markup inside the JSON strings; stop reading.
                        // (Backticks and "</" never occur in the JSON structure itself, unlike braces.)
                        if buffer.contains("`") || buffer.contains("</") { break }
                    }
                    var final = parse().cleaned()
                    if final.lemma.isEmpty { final.lemma = request.word.lowercased() }
                    if final.expression.isEmpty { final.expression = final.lemma }
                    continuation.yield(.complete(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Translates swept sentences into Korean with a local Ollama model.
public struct OllamaSentenceTranslator: Sendable {
    public var client: OllamaClient
    public var model: String

    public init(client: OllamaClient = OllamaClient(), model: String) {
        self.client = client
        self.model = model
    }

    /// Streams the translation so far, growing until it is complete.
    public func translate(_ text: String) -> AsyncThrowingStream<String, Error> {
        let stream = client.chatStream(model: model, messages: TranslationPrompt.messages(for: text), format: nil,
                                       options: ["temperature": 0.2, "num_predict": 800, "num_ctx": 2048])
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                do {
                    for try await chunk in stream {
                        buffer += chunk
                        continuation.yield(TranslationPrompt.clean(buffer))
                        if buffer.contains("</") || buffer.contains("```") { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension WordDefinition {
    /// Removes duplicate or redundant "other meanings" that small models tend to produce.
    public func cleaned() -> WordDefinition {
        var copy = self
        func key(_ s: String) -> String {
            // Ignore parenthetical qualifiers: "(사실을) 인정받다" duplicates "인정받다".
            s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && $0 != "·" }
        }
        let meaningKeys = Set(meaning.split(separator: ",").map { key(String($0)) })
        var seen = Set<String>()
        copy.otherMeanings = otherMeanings.compactMap { item -> String? in
            let k = key(item)
            guard !k.isEmpty, !meaningKeys.contains(k), k != key(meaning), seen.insert(k).inserted else { return nil }
            return item
        }
        copy.otherMeanings = Array(copy.otherMeanings.prefix(3))
        if copy.explanation == copy.meaning { copy.explanation = "" }
        return copy
    }
}

/// Definitions from the macOS built-in dictionary. Used when the local model is unavailable.
public struct SystemDictionaryProvider: MeaningProvider {
    public init() {}

    public static func definition(for word: String) -> String? {
        let cf = word as CFString
        guard let unmanaged = DCSCopyTextDefinition(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf))) else {
            return nil
        }
        return unmanaged.takeRetainedValue() as String
    }

    /// Splits a Dictionary.app plain-text entry ("run | rʌn | verb … 1 move …") into parts.
    public static func parse(word: String, text: String) -> WordDefinition {
        let parts = text.components(separatedBy: " | ")
        var headword = word.lowercased()
        var ipa = ""
        var body = text
        if parts.count >= 3 {
            headword = parts[0].trimmingCharacters(in: .whitespaces)
            ipa = "/" + parts[1].trimmingCharacters(in: .whitespaces) + "/"
            body = parts[2...].joined(separator: " | ")
        }
        let posWords = ["noun": "명사", "verb": "동사", "adjective": "형용사", "adverb": "부사", "preposition": "전치사",
                        "conjunction": "접속사", "pronoun": "대명사", "exclamation": "감탄사", "phrasal verb": "구동사"]
        var pos = ""
        let lowered = body.lowercased()
        var firstIndex = lowered.endIndex
        for (en, ko) in posWords {
            if let r = lowered.range(of: en), r.lowerBound < firstIndex {
                firstIndex = r.lowerBound
                pos = ko
            }
        }
        // Senses are numbered "1 …", "2 …"; take the first few as meanings.
        let numbered = body.split(separator: try! Regex(#"(?:^|\s)\d{1,2}\s"#)).map { String($0).trimmingCharacters(in: .whitespaces) }
        let definitions = numbered.dropFirst(numbered.count > 1 ? 1 : 0)
            .map { Self.firstClause($0) }
            .filter { !$0.isEmpty }
        let meaning = definitions.first ?? Self.firstClause(body)
        return WordDefinition(
            expression: headword,
            lemma: headword,
            partOfSpeech: pos,
            meaning: meaning,
            ipa: ipa,
            explanation: "로컬 AI를 사용할 수 없어 macOS 기본 사전(영영) 뜻을 표시합니다.",
            otherMeanings: Array(definitions.dropFirst().prefix(3)),
            source: "dictionary"
        )
    }

    static func firstClause(_ s: String) -> String {
        var text = s
        // Drop grammar labels like "[with object]" and example sentences after ":".
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 160 { text = String(text.prefix(160)) + "…" }
        return text
    }

    public func lookup(_ request: LookupRequest) -> AsyncThrowingStream<LookupEvent, Error> {
        AsyncThrowingStream { continuation in
            if let entry = request.dictionary, let first = entry.groups.first {
                continuation.yield(.complete(WordDefinition(
                    expression: entry.headword, lemma: entry.headword, partOfSpeech: first.pos,
                    meaning: first.glosses.first ?? "", ipa: entry.ipa,
                    explanation: "로컬 AI를 사용할 수 없어 사전 뜻만 표시합니다.", source: "dictionary", dictionary: entry)))
            } else if let text = Self.definition(for: request.word) ?? Self.definition(for: request.word.lowercased()) {
                continuation.yield(.complete(Self.parse(word: request.word, text: text)))
            } else {
                continuation.yield(.complete(WordDefinition(
                    expression: request.word, lemma: request.word.lowercased(),
                    meaning: "사전에서 찾을 수 없는 단어입니다.", source: "dictionary")))
            }
            continuation.finish()
        }
    }
}

/// Deterministic definitions for tests and offline demos.
public struct MockMeaningProvider: MeaningProvider {
    public var entries: [String: WordDefinition]
    public var delay: Duration

    public init(entries: [String: WordDefinition] = MockMeaningProvider.defaultEntries, delay: Duration = .milliseconds(50)) {
        self.entries = entries
        self.delay = delay
    }

    public static let defaultEntries: [String: WordDefinition] = [
        "ephemeral": WordDefinition(expression: "ephemeral", lemma: "ephemeral", partOfSpeech: "형용사", meaning: "잠깐 동안의, 덧없는",
                                    ipa: "/ɪˈfem(ə)rəl/", explanation: "오래 지속되지 않는 것을 묘사한다.", otherMeanings: ["단명하는"], source: "mock"),
        "bank": WordDefinition(expression: "bank", lemma: "bank", partOfSpeech: "명사", meaning: "은행", ipa: "/bæŋk/",
                               explanation: "돈을 맡기는 곳을 뜻한다.", otherMeanings: ["둑, 기슭"], source: "mock"),
    ]

    public func lookup(_ request: LookupRequest) -> AsyncThrowingStream<LookupEvent, Error> {
        let key = request.word.lowercased()
        let entry = entries[key] ?? WordDefinition(expression: key, lemma: key, partOfSpeech: "명사",
                                                   meaning: "(모의 데이터) \(key)의 뜻", source: "mock")
        let delay = self.delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                var partial = entry
                partial.otherMeanings = []
                partial.explanation = ""
                continuation.yield(.partial(partial))
                try? await Task.sleep(for: delay)
                continuation.yield(.complete(entry))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Tries the primary provider and falls back to the secondary if the primary fails before producing output.
public struct FallbackMeaningProvider: MeaningProvider {
    public var primary: MeaningProvider
    public var fallback: MeaningProvider

    public init(primary: MeaningProvider, fallback: MeaningProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func lookup(_ request: LookupRequest) -> AsyncThrowingStream<LookupEvent, Error> {
        let primary = self.primary, fallback = self.fallback
        return AsyncThrowingStream { continuation in
            let task = Task {
                var produced = false
                do {
                    for try await event in primary.lookup(request) {
                        produced = true
                        continuation.yield(event)
                    }
                    continuation.finish()
                    return
                } catch {
                    if produced || Task.isCancelled {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                do {
                    for try await event in fallback.lookup(request) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
