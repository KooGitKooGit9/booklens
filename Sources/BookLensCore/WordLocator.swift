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
        /// Longest text translated from one sweep.
        public var maxSweepLength = 1500
        public init() {}
    }

    /// - Parameter imageSize: size of the captured image. When given, lines cut off by the capture
    ///   edges end the context there, so partial lines are not stitched into the sentence.
    public static func locate(point: CGPoint, in lines: [RecognizedLine], imageSize: CGSize? = nil, options: Options = Options()) -> WordHit? {
        guard let lineIndex = lineIndex(at: point, in: lines, options: options) else { return nil }
        let line = lines[lineIndex]
        guard let wordIndex = wordIndex(at: point, in: line, options: options) else { return nil }
        let word = line.words[wordIndex]

        // Reconstruct running text for the column the line belongs to.
        let column = ColumnText(around: lineIndex, in: lines, imageSize: imageSize)
        let joined = column.chars
        let targetOffset = column.offset(ofWord: wordIndex, inLine: lineIndex, lines: lines) ?? 0

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

        return WordHit(word: surface, rect: wordRect, sentence: sentence, context: context, confidence: line.confidence)
    }

    /// The sentence or sentences the mouse swept across: every sentence containing a word under one of
    /// `points`, taken from the column of the first word hit. Returns nil if no point is over a word.
    public static func locateSentence(along points: [CGPoint], in lines: [RecognizedLine], imageSize: CGSize? = nil,
                                      options: Options = Options()) -> SentenceHit? {
        let hits = points.compactMap { point -> (line: Int, word: Int)? in
            guard let li = lineIndex(at: point, in: lines, options: options),
                  let wi = wordIndex(at: point, in: lines[li], options: options) else { return nil }
            return (li, wi)
        }
        guard let first = hits.first else { return nil }
        let column = ColumnText(around: first.line, in: lines, imageSize: imageSize)
        let chars = column.chars
        let offsets = hits.compactMap { column.offset(ofWord: $0.word, inLine: $0.line, lines: lines) }
        guard let lo = offsets.min(), let hi = offsets.max(), !chars.isEmpty else { return nil }
        let hiEnd = expandToWordBoundary(chars, min(hi, chars.count), backward: false)
        let (start, end) = sentenceBounds(in: chars, wordStart: lo, wordEnd: hiEnd, maxLength: options.maxSweepLength)
        let text = clean(String(chars[start..<end]))
        guard !text.isEmpty else { return nil }
        let cStart = expandToWordBoundary(chars, max(0, start - options.contextRadius), backward: true)
        let cEnd = expandToWordBoundary(chars, min(chars.count, end + options.contextRadius), backward: false)

        // Highlight: per line, the words inside the sentence range.
        var rects: [CGRect] = []
        for li in column.order {
            var union: CGRect?
            for wi in lines[li].words.indices {
                guard let off = column.offset(ofWord: wi, inLine: li, lines: lines), off >= start, off < end else { continue }
                union = union?.union(lines[li].words[wi].rect) ?? lines[li].words[wi].rect
            }
            if let union { rects.append(union) }
        }
        return SentenceHit(text: text, context: clean(String(chars[cStart..<cEnd])), lineRects: rects)
    }

    /// Running text of one column, with the offset where each line starts.
    struct ColumnText {
        var chars: [Character] = []
        /// Column lines in reading order.
        var order: [Int] = []
        /// Offset in `chars` of each line's trimmed text, and how many leading spaces were trimmed.
        var starts: [Int: (offset: Int, leading: Int)] = [:]

        init(around lineIndex: Int, in lines: [RecognizedLine], imageSize: CGSize?) {
            var column = WordLocator.columnLines(for: lineIndex, in: lines)
            if let size = imageSize, let pos = column.firstIndex(of: lineIndex) {
                let edge: CGFloat = 2
                func clipped(_ i: Int) -> Bool {
                    let r = lines[i].rect
                    return r.minX <= edge || r.maxX >= size.width - edge || r.minY <= edge || r.maxY >= size.height - edge
                }
                var lo = pos, hi = pos
                while lo > 0, !clipped(column[lo - 1]) { lo -= 1 }
                while hi < column.count - 1, !clipped(column[hi + 1]) { hi += 1 }
                column = Array(column[lo...hi])
            }
            order = column
            for idx in column {
                let text = Array(lines[idx].text.trimmingCharacters(in: .whitespaces))
                if !chars.isEmpty {
                    if let last = chars.last, Tokenizer.isHyphen(last),
                       chars.count >= 2, chars[chars.count - 2].isLetter,
                       let first = text.first, first.isLowercase {
                        chars.removeLast() // de-hyphenate "exam-" + "ple"
                    } else {
                        chars.append(" ")
                    }
                }
                starts[idx] = (chars.count, lines[idx].text.prefix { $0 == " " }.count)
                chars.append(contentsOf: text)
            }
        }

        /// Offset in `chars` of a word, or nil if its line is not in this column.
        func offset(ofWord wordIndex: Int, inLine lineIndex: Int, lines: [RecognizedLine]) -> Int? {
            guard let start = starts[lineIndex] else { return nil }
            return start.offset + max(0, WordLocator.characterOffset(ofWordAt: wordIndex, in: lines[lineIndex]) - start.leading)
        }
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
