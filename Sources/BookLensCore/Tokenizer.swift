import Foundation

public enum Tokenizer {
    /// A token found in a string: its trimmed text and the range it occupies.
    public struct Token: Equatable {
        public var text: String
        public var range: Range<String.Index>
    }

    private static let joiners: Set<Character> = ["'", "’", "-", "‐", "‑"]

    /// Splits `text` into word tokens. A word is a run of letters/digits that may contain
    /// internal apostrophes or hyphens ("don't", "well-known"). Trailing hyphens are kept
    /// so callers can detect words broken across lines ("exam-").
    public static func words(in text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard isWordChar(text[i]) else {
                i = text.index(after: i)
                continue
            }
            let start = i
            var end = text.index(after: i)
            while end < text.endIndex {
                let c = text[end]
                if isWordChar(c) {
                    end = text.index(after: end)
                } else if joiners.contains(c) {
                    let next = text.index(after: end)
                    if next < text.endIndex, isWordChar(text[next]) {
                        end = next
                    } else if isHyphen(c), next == text.endIndex {
                        // Line-final hyphen: keep it as part of the word.
                        end = next
                        break
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
            tokens.append(Token(text: String(text[start..<end]), range: start..<end))
            i = end
        }
        return tokens
    }

    public static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    public static func isHyphen(_ c: Character) -> Bool {
        c == "-" || c == "‐" || c == "‑"
    }

    /// Normalizes typographic variants so words compare equal ("don’t" == "don't").
    public static func normalize(_ word: String) -> String {
        word.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‐", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
    }

    /// True if the token is worth looking up (contains at least one Latin letter).
    public static func isLookupCandidate(_ word: String) -> Bool {
        word.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }
}
