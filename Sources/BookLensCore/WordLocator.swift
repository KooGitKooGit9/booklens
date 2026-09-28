import CoreGraphics
import Foundation

/// Finds the word under a point and reconstructs the surrounding sentence from OCR lines.
public enum WordLocator {
    public struct Options: Sendable {
        /// How far outside a word box (in multiples of line height) a point may be and still hit it.
        public var horizontalTolerance: CGFloat = 0.45
        /// Vertical slack around a line box, in multiples of line height.
        public var verticalTolerance: CGFloat = 0.3
        public var maxSentenceLength = 420
        public var contextRadius = 280
        public init() {}
    }

    public static func locate(point: CGPoint, in lines: [RecognizedLine], options: Options = Options()) -> WordHit? {
        guard let lineIndex = lineIndex(at: point, in: lines, options: options) else { return nil }
        let line = lines[lineIndex]
        guard let wordIndex = wordIndex(at: point, in: line, options: options) else { return nil }
        let word = line.words[wordIndex]

        // Reconstruct running text for the column the line belongs to.
        let column = columnLines(for: lineIndex, in: lines)
        var joined: [Character] = []
        var targetOffset = 0
        for idx in column {
            let text = Array(lines[idx].text.trimmingCharacters(in: .whitespaces))
            if !joined.isEmpty {
                if let last = joined.last, Tokenizer.isHyphen(last),
                   joined.count >= 2, joined[joined.count - 2].isLetter,
                   let first = text.first, first.isLowercase {
                    joined.removeLast() // de-hyphenate "exam-" + "ple"
                } else {
                    joined.append(" ")
                }
            }
            if idx == lineIndex {
                let leading = lines[idx].text.prefix { $0 == " " }.count
                targetOffset = joined.count + max(0, characterOffset(ofWordAt: wordIndex, in: line) - leading)
            }
            joined.append(contentsOf: text)
        }

        let joinedString = String(joined)
        let tokens = Tokenizer.words(in: joinedString)
        let token = tokens.first { tok in
            let s = joinedString.distance(from: joinedString.startIndex, to: tok.range.lowerBound)
            let e = joinedString.distance(from: joinedString.startIndex, to: tok.range.upperBound)
            return targetOffset >= s && targetOffset < e
        }
        var surface = token?.text ?? word.text
        while let last = surface.last, Tokenizer.isHyphen(last) { surface.removeLast() }
        surface = Tokenizer.normalize(surface)
        var wordRect = word.rect
        // OCR often reads an em dash as a hyphen ("hopes—however" → "hopes-however"), so for
        // hyphen-joined words on one line pick the part under the cursor. The model still sees
        // the full sentence and can report a real compound ("well-known") as the expression.
        var lineWord = Tokenizer.normalize(word.text)
        while let last = lineWord.last, Tokenizer.isHyphen(last) { lineWord.removeLast() }
        if surface.contains("-"), lineWord == surface, wordRect.width > 0 {
            let parts = surface.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let fraction = min(max((point.x - wordRect.minX) / wordRect.width, 0), 0.999)
            let index = fraction * CGFloat(surface.count)
            var offset = 0
            for part in parts {
                let end = offset + part.count
                if index < CGFloat(end) + 0.5 || part == parts.last {
                    let unit = wordRect.width / CGFloat(surface.count)
                    wordRect = CGRect(x: wordRect.minX + CGFloat(offset) * unit, y: wordRect.minY,
                                      width: CGFloat(part.count) * unit, height: wordRect.height)
                    surface = part
                    break
                }
                offset = end + 1
            }
        }
        guard Tokenizer.isLookupCandidate(surface) else { return nil }

        let wordStart = token.map { joinedString.distance(from: joinedString.startIndex, to: $0.range.lowerBound) } ?? targetOffset
        let wordEnd = token.map { joinedString.distance(from: joinedString.startIndex, to: $0.range.upperBound) } ?? targetOffset + surface.count
        let (sStart, sEnd) = sentenceBounds(in: joined, wordStart: wordStart, wordEnd: wordEnd, maxLength: options.maxSentenceLength)
        let sentence = clean(String(joined[sStart..<sEnd]))
        let cStart = expandToWordBoundary(joined, max(0, sStart - options.contextRadius), backward: true)
        let cEnd = expandToWordBoundary(joined, min(joined.count, sEnd + options.contextRadius), backward: false)
        let context = clean(String(joined[cStart..<cEnd]))

        return WordHit(word: surface, rect: wordRect, sentence: sentence, context: context)
    }

    // MARK: - Hit testing

    static func lineIndex(at point: CGPoint, in lines: [RecognizedLine], options: Options) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, line) in lines.enumerated() where !line.words.isEmpty {
            let h = line.rect.height
            let area = line.rect.insetBy(dx: -h * options.horizontalTolerance, dy: -h * options.verticalTolerance)
            guard area.contains(point) else { continue }
            let d = abs(point.y - line.rect.midY)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    static func wordIndex(at point: CGPoint, in line: RecognizedLine, options: Options) -> Int? {
        let tolerance = line.rect.height * options.horizontalTolerance
        var best: (index: Int, distance: CGFloat)?
        for (i, word) in line.words.enumerated() {
            let r = word.rect
            let dx: CGFloat
            if point.x < r.minX { dx = r.minX - point.x } else if point.x > r.maxX { dx = point.x - r.maxX } else { dx = 0 }
            guard dx <= tolerance else { continue }
            if best == nil || dx < best!.distance { best = (i, dx) }
        }
        return best?.index
    }

    /// Character offset of the n-th word within its line text.
    static func characterOffset(ofWordAt index: Int, in line: RecognizedLine) -> Int {
        let tokens = Tokenizer.words(in: line.text)
        if tokens.count == line.words.count, index < tokens.count {
            return line.text.distance(from: line.text.startIndex, to: tokens[index].range.lowerBound)
        }
        if let r = line.text.range(of: line.words[index].text) {
            return line.text.distance(from: line.text.startIndex, to: r.lowerBound)
        }
        return 0
    }

    /// Lines belonging to the same text column as `index`, in reading order.
    static func columnLines(for index: Int, in lines: [RecognizedLine]) -> [Int] {
        let target = lines[index].rect
        let members = lines.indices.filter { i in
            let r = lines[i].rect
            let overlap = min(r.maxX, target.maxX) - max(r.minX, target.minX)
            let minWidth = min(r.width, target.width)
            // Short lines (paragraph ends, headings) overlap mostly with the column; long lines must share most width.
            return overlap > 0 && overlap >= minWidth * 0.5
        }
        return members.sorted { a, b in
            let ra = lines[a].rect, rb = lines[b].rect
            let sameRow = abs(ra.midY - rb.midY) < min(ra.height, rb.height) * 0.5
            return sameRow ? ra.minX < rb.minX : ra.minY < rb.minY
        }
    }

    // MARK: - Sentences

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "prof", "mt", "no", "vol", "fig", "gen", "col", "capt", "lt", "sgt", "rev", "u.s", "a.m", "p.m",
    ]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    static func isSentenceEnd(_ chars: [Character], at i: Int) -> Bool {
        let c = chars[i]
        guard c == "." || c == "!" || c == "?" || c == "…" else { return false }
        // Must be followed by whitespace/end (possibly after closing quotes).
        var j = i + 1
        while j < chars.count, closers.contains(chars[j]) { j += 1 }
        if j < chars.count, !chars[j].isWhitespace { return false }
        if c == "." {
            // Skip abbreviations such as "Mr." or "e.g."
            var k = i - 1
            while k >= 0, chars[k].isLetter || chars[k] == "." { k -= 1 }
            let word = String(chars[(k + 1)..<i]).lowercased()
            if abbreviations.contains(word) { return false }
            if word.count == 1, let ch = word.first, ch.isLetter, i >= 1, chars[i - 1].isUppercase { return false } // initials "J."
        }
        return true
    }

    static func sentenceBounds(in chars: [Character], wordStart: Int, wordEnd: Int, maxLength: Int) -> (Int, Int) {
        var start = 0
        var i = wordStart - 1
        while i >= 0 {
            if isSentenceEnd(chars, at: i) {
                start = i + 1
                while start < chars.count, closers.contains(chars[start]) { start += 1 }
                while start < chars.count, chars[start].isWhitespace { start += 1 }
                break
            }
            i -= 1
        }
        var end = chars.count
        i = wordEnd
        while i < chars.count {
            if isSentenceEnd(chars, at: i) {
                end = i + 1
                while end < chars.count, closers.contains(chars[end]) { end += 1 }
                break
            }
            i += 1
        }
        if end - start > maxLength {
            let half = maxLength / 2
            start = expandToWordBoundary(chars, max(start, wordStart - half), backward: true)
            end = expandToWordBoundary(chars, min(end, wordEnd + half), backward: false)
        }
        return (min(start, wordStart), max(end, wordEnd))
    }

    static func expandToWordBoundary(_ chars: [Character], _ index: Int, backward: Bool) -> Int {
        var i = index
        if backward {
            while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        } else {
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
        }
        return i
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
