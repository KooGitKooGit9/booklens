import Foundation

/// A saved vocabulary entry.
public struct VocabEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var word: String
    public var definition: WordDefinition
    public var sentence: String
    public var sourceTitle: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lookupCount: Int

    public init(id: UUID = UUID(), word: String, definition: WordDefinition, sentence: String, sourceTitle: String,
                createdAt: Date = Date(), updatedAt: Date = Date(), lookupCount: Int = 1) {
        self.id = id
        self.word = word
        self.definition = definition
        self.sentence = sentence
        self.sourceTitle = sourceTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lookupCount = lookupCount
    }

    /// Entries are deduplicated by expression (falls back to lemma, then the surface word).
    public var key: String {
        let k = definition.expression.isEmpty ? (definition.lemma.isEmpty ? word : definition.lemma) : definition.expression
        return k.lowercased()
    }
}

/// Persists the vocabulary list as JSON in Application Support.
public final class VocabStore: @unchecked Sendable {
    public private(set) var entries: [VocabEntry] = []
    public let fileURL: URL
    private let queue = DispatchQueue(label: "booklens.vocabstore")

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BookLens", isDirectory: true).appendingPathComponent("vocabulary.json")
    }

    public init(fileURL: URL = VocabStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([VocabEntry].self, from: data) {
            entries = decoded
        } else {
            // Keep a copy of an unreadable file instead of silently overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Adds a lookup, or bumps the count of an existing entry with the same expression.
    @discardableResult
    public func record(word: String, definition: WordDefinition, sentence: String, sourceTitle: String, now: Date = Date()) -> VocabEntry {
        var entry = VocabEntry(word: word, definition: definition, sentence: sentence, sourceTitle: sourceTitle, createdAt: now, updatedAt: now)
        if let i = entries.firstIndex(where: { $0.key == entry.key }) {
            var existing = entries[i]
            existing.lookupCount += 1
            existing.updatedAt = now
            existing.definition = definition
            existing.sentence = sentence
            existing.word = word
            if !sourceTitle.isEmpty { existing.sourceTitle = sourceTitle }
            entries.remove(at: i)
            entry = existing
        }
        entries.insert(entry, at: 0)
        try? save()
        return entry
    }

    public func remove(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        try? save()
    }

    public func removeAll() {
        entries.removeAll()
        try? save()
    }

    public func contains(expression: String) -> Bool {
        entries.contains { $0.key == expression.lowercased() }
    }

    /// Anki-importable CSV: Front (expression), Back (meaning + details), Sentence, Source.
    public func csv(for selection: [VocabEntry]? = nil) -> String {
        var rows = ["Front,Back,Sentence,Source,Lookups,Added"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for e in selection ?? entries {
            let d = e.definition
            var back = [d.partOfSpeech, d.meaning].filter { !$0.isEmpty }.joined(separator: " ")
            if !d.ipa.isEmpty { back += " \(d.ipa)" }
            if !d.otherMeanings.isEmpty { back += " / 그 외: " + d.otherMeanings.joined(separator: ", ") }
            let front = d.expression.isEmpty ? e.word : d.expression
            rows.append([front, back, e.sentence, e.sourceTitle, String(e.lookupCount), formatter.string(from: e.createdAt)]
                .map(Self.csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
