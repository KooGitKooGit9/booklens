import Foundation

/// Dictionary senses of a word, grouped by part of speech.
public struct DictionaryEntry: Codable, Equatable, Hashable, Sendable {
    public struct Group: Codable, Equatable, Hashable, Sendable {
        /// Part of speech in Korean ("명사", "동사").
        public var pos: String
        /// Short Korean glosses, most common first.
        public var glosses: [String]

        public init(pos: String, glosses: [String]) {
            self.pos = pos
            self.glosses = glosses
        }
    }

    /// Dictionary form ("keeps" → "keep").
    public var headword: String
    public var ipa: String
    public var groups: [Group]

    public init(headword: String, ipa: String = "", groups: [Group]) {
        self.headword = headword
        self.ipa = ipa
        self.groups = groups
    }

    /// One line per part of speech, for the model prompt.
    public var promptText: String {
        groups.map { "\($0.pos): \($0.glosses.joined(separator: ", "))" }.joined(separator: " / ")
    }
}

/// Looks words up in the English–Korean dictionary that ships with macOS (뉴에이스 영한사전).
///
/// Dictionary Services has no public API for choosing a dictionary or listing homographs, so the
/// private DCS functions are resolved at runtime; if any is missing the dictionary is simply unavailable.
public final class KoreanDictionary: @unchecked Sendable {
    public static let shared = KoreanDictionary()

    private typealias CopyDictionaries = @convention(c) () -> Unmanaged<CFSet>?
    private typealias GetName = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias CopyRecords = @convention(c) (CFTypeRef, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias GetHeadword = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias CopyData = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFString>?

    private let dictionary: CFTypeRef?
    private let copyRecords: CopyRecords?
    private let getHeadword: GetHeadword?
    private let copyData: CopyData?
    private let lock = NSLock()

    /// Record data version that returns plain text (0–2 return HTML).
    private static let plainTextVersion = 3

    public var isAvailable: Bool { dictionary != nil }

    private init() {
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
            return unsafeBitCast(p, to: T.self)
        }
        let copyDictionaries = symbol("DCSCopyAvailableDictionaries", as: CopyDictionaries.self)
        let getName = symbol("DCSDictionaryGetName", as: GetName.self)
        copyRecords = symbol("DCSCopyRecordsForSearchString", as: CopyRecords.self)
        getHeadword = symbol("DCSRecordGetHeadword", as: GetHeadword.self)
        copyData = symbol("DCSRecordCopyData", as: CopyData.self)

        var found: CFTypeRef?
        if let copyDictionaries, let getName, copyRecords != nil, getHeadword != nil, copyData != nil,
           let all = copyDictionaries()?.takeRetainedValue() as NSSet? {
            found = all.first { item in
                let name = getName(item as CFTypeRef)?.takeUnretainedValue() as String? ?? ""
                return name.contains("영한") || name.contains("English-Korean")
            } as CFTypeRef?
        }
        dictionary = found
    }

    public func lookup(_ word: String) -> DictionaryEntry? {
        guard let dictionary, let copyRecords, let getHeadword, let copyData else { return nil }
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Tokenizer.isLookupCandidate(term), !Self.functionWords.contains(term.lowercased()) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let array = copyRecords(dictionary, term as CFString, nil, nil)?.takeRetainedValue() as NSArray? else { return nil }
        let records: [(headword: String, text: String)] = array.prefix(8).compactMap { item in
            let record = item as CFTypeRef
            guard let text = copyData(record, Self.plainTextVersion)?.takeRetainedValue() as String? else { return nil }
            let headword = getHeadword(record)?.takeUnretainedValue() as String? ?? term
            return (headword, text)
        }
        return Self.entry(for: term, records: records)
    }

    // MARK: - Parsing

    struct Section: Equatable {
        var pos: String
        /// Distinguishes 타동사/자동사 and homographs, which are interleaved when picking glosses.
        var key: String
        var glosses: [String]
    }

    struct Record: Equatable {
        var headword: String
        /// Homograph number ("wind 2" → 2).
        var homograph: Int?
        var ipa: String
        var sections: [Section]
        var isInflectionPointer: Bool
        /// Homographs an inflection pointer refers to ("wind², wind³의 과거" → [2, 3]).
        var pointerTargets: Set<Int> = []
    }

    static let maxGlossesPerGroup = 5
    /// Entries that are mostly usage notes; the model explains these better.
    static let functionWords: Set<String> = ["a", "an", "the"]

    /// Combines the records found for `word` into one entry.
    static func entry(for word: String, records raw: [(headword: String, text: String)]) -> DictionaryEntry? {
        var records = raw.enumerated().map { i, r in parseRecord(r.text, headword: r.headword, index: i) }
        records.removeAll { $0.sections.isEmpty }
        let lowerWord = word.lowercased()
        // "ran" finds "ran (명사) 연사", "ran → run 의 과거형" and "run": keep the lemma's records, and the
        // word's own records only when they are substantial ("wound" is also 상처, a full entry).
        if records.contains(where: \.isInflectionPointer) {
            let targets = records.reduce(into: Set<Int>()) { $0.formUnion($1.pointerTargets) }
            let kept = records.filter { r in
                guard !r.isInflectionPointer else { return false }
                if r.headword.lowercased() == lowerWord { return r.sections.reduce(0) { $0 + $1.glosses.count } >= 3 }
                // "wound" is the past of wind² (감다), not of wind¹ (바람).
                return targets.isEmpty || r.homograph.map(targets.contains) ?? true
            }
            if kept.contains(where: { $0.headword.lowercased() != lowerWord }) { records = kept }
        }
        // Proper nouns ("Ran") and affixes ("counter-") only when nothing else matched.
        if records.contains(where: { $0.headword.first?.isLowercase == true }) {
            records.removeAll { $0.headword.first?.isUppercase == true }
        }
        let words = records.filter { !$0.headword.hasPrefix("-") && !$0.headword.hasSuffix("-") }
        if !words.isEmpty { records = words }
        guard let first = records.first else { return nil }

        var order: [String] = []
        var sectionsByPOS: [String: [Section]] = [:]
        for section in records.flatMap(\.sections) where !section.glosses.isEmpty {
            if sectionsByPOS[section.pos] == nil { order.append(section.pos) }
            sectionsByPOS[section.pos, default: []].append(section)
        }
        let groups: [DictionaryEntry.Group] = order.compactMap { pos in
            let sections = sectionsByPOS[pos] ?? []
            // Round-robin over sections so 자동사 and later homographs ("fork 2: [컴퓨터] …") get a slot.
            var picked: [String] = []
            var seen = Set<String>()
            let depth = sections.map(\.glosses.count).max() ?? 0
            for i in 0..<depth {
                for s in sections where i < s.glosses.count {
                    if seen.insert(s.glosses[i]).inserted { picked.append(s.glosses[i]) }
                }
            }
            // Pattern glosses ("항상 …하다") read poorly out of context; list them last.
            picked = picked.filter { !$0.contains("…") } + picked.filter { $0.contains("…") }
            return picked.isEmpty ? nil : DictionaryEntry.Group(pos: pos, glosses: Array(picked.prefix(maxGlossesPerGroup)))
        }
        guard !groups.isEmpty else { return nil }
        let ipa = first.ipa.isEmpty ? "" : "/\(first.ipa)/"
        return DictionaryEntry(headword: first.headword, ipa: ipa, groups: groups)
    }

    private static let posNames = ["타동사", "자동사", "조동사", "대명사", "형용사", "전치사", "접속사", "감탄사", "한정사",
                                   "접두사", "접미사", "명사", "동사", "부사", "관사", "약어", "숙어"]
    /// A part-of-speech label at a section start, followed by a sense number, inflections, a label or the
    /// pronunciation — not one mentioned in a usage note ("복수 동사로 호응하며", "down은 부사."). Directly
    /// followed by the gloss ("형용사덧없는; …. 명사단명한 것") only at the start or after a sentence.
    private static let headerRegex: NSRegularExpression = {
        let names = posNames.joined(separator: "|")
        let labelled = #"(?:^|(?<=[\s.,)）\]|」]))(타동사|자동사|(?:"# + names + #")(?=[\d(（,，〈〔［\[①-⑳…A-Za-z]|\s*\||\s+[A-Za-z\d]|\s*$))"#
        let bare = #"(?:^|(?<=\.)|(?<=\. ))((?:"# + names + #")(?=[가-힣]))"#
        return try! NSRegularExpression(pattern: labelled + "|" + bare)
    }()
    private static let senseNumberRegex = try! NSRegularExpression(pattern: #"(?:^|(?<=[\s.)）\]|]))\d{1,2}\.(?!\d)"#)
    private static let inflectionRegex = try! NSRegularExpression(pattern: #"의\s*(과거|과거분사|복수|비교급|최상급|현재분사|3인칭)"#)

    /// Parses Dictionary Services' plain text: "count·er 1 | káuntər | 명사1.（은행 등의） 계산대, 카운터 … 2.…".
    static func parseRecord(_ text: String, headword fallback: String, index: Int) -> Record {
        let parts = text.components(separatedBy: " | ")
        var headword = fallback
        var homograph: Int?
        var ipa = ""
        var body = text
        if parts.count >= 3 {
            headword = parts[0]
            homograph = parts[0].split(separator: " ").last.flatMap { Int($0) }
            // First variant only: "prɑ́ses┃próu-", "wind 《고어·시어》 waind", "káuntər-,-̀-".
            ipa = parts[1].split(whereSeparator: { ",┃;《( ".contains($0) }).first.map(String.init) ?? ""
            body = parts[2...].joined(separator: " | ")
        }
        headword = headword.replacingOccurrences(of: "·", with: "")
            .replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if headword.isEmpty { headword = fallback }
        // Slang and archaic senses ("《속어》 마약을 하고 있다") are marked so `gloss(from:)` skips them.
        body = body.replacingOccurrences(of: #"《(속어|비어|고어|방언|폐어)[^》]*》"#, with: Self.skipMarker, options: .regularExpression)
        // Usage labels can contain part-of-speech words: 《양태 부사(구)와 함께》.
        body = body.replacingOccurrences(of: #"《[^》]*》|『[^』]*』|【[^】]*】|\(※[^)]*\)"#, with: " ", options: .regularExpression)

        let ns = body as NSString
        let matches = headerRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var sections: [Section] = []
        for (i, m) in matches.enumerated() {
            let name = ns.substring(with: m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2))
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let start = m.range.location + m.range.length
            let content = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            if name == "숙어" { continue }
            let pos = name == "타동사" || name == "자동사" ? "동사" : name
            let key = "\(index):\(name)"
            let glosses = senses(in: content).compactMap(gloss(from:))
            if glosses.isEmpty { continue }
            if let last = sections.last, last.key == key {
                sections[sections.count - 1].glosses += glosses
            } else {
                sections.append(Section(pos: pos, key: key, glosses: glosses))
            }
        }
        let pointer = inflectionRegex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) != nil
            && sections.allSatisfy { $0.glosses.allSatisfy { $0.contains("의") } }
        var targets = Set<Int>()
        if pointer {
            let superscripts: [Character: Int] = ["¹": 1, "²": 2, "³": 3, "⁴": 4, "⁵": 5]
            targets = Set(body.compactMap { superscripts[$0] })
        }
        return Record(headword: headword, homograph: homograph, ipa: ipa, sections: sections,
                      isInflectionPointer: pointer, pointerTargets: targets)
    }

    /// Splits a part-of-speech section into numbered senses ("1.…", "2.…"); unnumbered sections are one sense.
    static func senses(in content: String) -> [String] {
        let ns = content as NSString
        let numbers = senseNumberRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !numbers.isEmpty else { return [content] }
        return numbers.enumerated().map { i, m in
            let start = m.range.location + m.range.length
            let end = i + 1 < numbers.count ? numbers[i + 1].range.location : ns.length
            return ns.substring(with: NSRange(location: start, length: max(0, end - start)))
        }
    }

    /// The first short gloss of a sense: "①농업용 포크, 갈퀴 ▸ a hay fork…" → "농업용 포크, 갈퀴".
    static let skipMarker = "\u{E000}"

    static func gloss(from sense: String) -> String? {
        if sense.contains(skipMarker) { return nil }
        var s = sense
        if let r = s.range(of: "▸") { s = String(s[..<r.lowerBound]) } // examples
        // Labels, objects and notes: 〈도구 등을〉, 〔체스〕, ［…］, （은행 등의）, (※…), [불]; an unclosed one runs to the end.
        s = s.replacingOccurrences(of: #"〈[^〉]*(〉|$)|〔[^〕]*(〕|$)|［[^］]*(］|$)|[（(][^）)]*([）)]|$)|\[[^\]]*(\]|$)"#,
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[①-⑳「」]"#, with: "", options: .regularExpression)
        for stop in [";", "；", ": ", ". ", " cf."] {
            if let r = s.range(of: stop) { s = String(s[..<r.lowerBound]) }
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(\s+[A-Za-z()'’-]+)+\s*$"#, with: "", options: .regularExpression) // "측정기 COUNTER)"
        var items = s.split(separator: ",").map { item -> String in
            item.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^…\s*(을|를|에게|에서|에|이|가|의|과|와|으로|로)?\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .。"))
        }
        // Keep Korean glosses; drop usage notes that start with a particle ("가 복수", "의 최상급에는").
        items.removeAll { item in
            !item.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
                || item.range(of: #"^(가|의|는|은|를|을|에|나|와|과|로)\s"#, options: .regularExpression) != nil
        }
        guard var result = items.first else { return nil }
        if items.count > 1, result.count + items[1].count <= 8 { result += ", " + items[1] }
        if result.count > 18 { result = String(result.prefix(17)) + "…" }
        return result
    }
}
