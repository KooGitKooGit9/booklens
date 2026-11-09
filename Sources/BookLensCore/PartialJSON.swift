import Foundation

/// Tolerant parser for a JSON object that may be cut off mid-stream.
/// Only string and string-array values are extracted, which is all the definition schema uses.
public enum PartialJSON {
    public enum Value: Equatable {
        case string(String)
        case strings([String])
    }

    public static func parseObject(_ text: String) -> [String: Value] {
        var p = Parser(chars: Array(text))
        return p.object()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(chars: [Character]) { self.chars = chars }

        mutating func skipWhitespace() {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }

        mutating func object() -> [String: Value] {
            var result: [String: Value] = [:]
            // Allow leading junk such as ```json fences.
            while i < chars.count, chars[i] != "{" { i += 1 }
            guard i < chars.count else { return result }
            i += 1
            while true {
                skipWhitespace()
                guard i < chars.count else { return result }
                if chars[i] == "}" { return result }
                if chars[i] == "," { i += 1; continue }
                guard chars[i] == "\"" else { return result }
                guard let (key, closed) = string(), closed else { return result }
                skipWhitespace()
                guard i < chars.count, chars[i] == ":" else { return result }
                i += 1
                skipWhitespace()
                guard i < chars.count else { return result }
                switch chars[i] {
                case "\"":
                    guard let (value, closed) = string() else { return result }
                    result[key] = .string(value)
                    if !closed { return result }
                case "[":
                    let (values, closed) = stringArray()
                    result[key] = .strings(values)
                    if !closed { return result }
                default:
                    skipScalar()
                }
            }
        }

        /// Parses a string starting at the opening quote. Returns the (possibly partial) value and whether it was closed.
        mutating func string() -> (String, Bool)? {
            guard i < chars.count, chars[i] == "\"" else { return nil }
            i += 1
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { i += 1; return (out, true) }
                if c == "\\" {
                    guard i + 1 < chars.count else { i += 1; return (out, false) }
                    let e = chars[i + 1]
                    switch e {
                    case "n": out.append("\n"); i += 2
                    case "t": out.append("\t"); i += 2
                    case "r": i += 2
                    case "b", "f": i += 2
                    case "u":
                        guard i + 5 < chars.count else { i = chars.count; return (out, false) }
                        let hex = String(chars[(i + 2)...(i + 5)])
                        if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                            out.unicodeScalars.append(scalar)
                        }
                        i += 6
                    default: out.append(e); i += 2
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            return (out, false)
        }

        mutating func stringArray() -> ([String], Bool) {
            i += 1 // [
            var values: [String] = []
            while true {
                skipWhitespace()
                guard i < chars.count else { return (values, false) }
                if chars[i] == "]" { i += 1; return (values, true) }
                if chars[i] == "," { i += 1; continue }
                if chars[i] == "\"" {
                    guard let (v, closed) = string() else { return (values, false) }
                    if closed { values.append(v) } else { return (values, false) }
                } else {
                    skipScalar()
                }
            }
        }

        mutating func skipScalar() {
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "{" || c == "[" { depth += 1 }
                if c == "}" || c == "]" {
                    if depth == 0 { return }
                    depth -= 1
                }
                if c == ",", depth == 0 { return }
                if c == "\"" { _ = string(); continue }
                i += 1
            }
        }
    }
}

extension WordDefinition {
    /// Text a small model emits when it loses track of the JSON ("…`,`other_meanings`:[]}```}</think>…").
    /// None of it belongs in a dictionary gloss.
    static let garbageMarkers = ["`", "</", "<think", "{", "}"]

    /// Trims whitespace and cuts the value at the first garbage marker.
    static func sanitized(_ value: String) -> String {
        var s = Substring(value)
        if let cut = garbageMarkers.compactMap({ s.range(of: $0)?.lowerBound }).min() { s = s[..<cut] }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a definition from the model's (possibly partial) JSON output.
    public static func fromModelJSON(_ text: String, source: String) -> WordDefinition {
        let dict = PartialJSON.parseObject(text)
        func str(_ key: String) -> String {
            if case .string(let s)? = dict[key] { return sanitized(s) }
            return ""
        }
        var others: [String] = []
        if case .strings(let a)? = dict["other_meanings"] {
            others = a.map(sanitized).filter { !$0.isEmpty }
        }
        return WordDefinition(
            expression: str("expression"),
            lemma: str("lemma"),
            partOfSpeech: str("pos"),
            meaning: str("meaning"),
            ipa: str("ipa"),
            explanation: str("explanation"),
            otherMeanings: others,
            source: source
        )
    }
}
