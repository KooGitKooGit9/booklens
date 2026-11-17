import CoreGraphics
import Foundation
import Vision

/// On-device OCR using Apple's Vision framework. Returns lines with per-word boxes.
public final class TextRecognizer: @unchecked Sendable {
    public enum Level: Sendable { case fast, accurate }

    public var languages: [String]
    public var level: Level
    public var usesLanguageCorrection: Bool

    public init(languages: [String] = ["en-US"], level: Level = .accurate, usesLanguageCorrection: Bool = true) {
        self.languages = languages
        self.level = level
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public enum RecognitionError: Error {
        case failed(Error)
    }

    /// Recognizes text in `image`. All returned rects are in image pixel coordinates, origin top-left.
    public func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.failed(error)
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        func toPixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * width,
                   y: (1 - r.maxY) * height,
                   width: r.width * width,
                   height: r.height * height)
        }

        var lines: [RecognizedLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let lineRect = toPixels(observation.boundingBox)
            let tokens = Tokenizer.words(in: text)
            let chunks = Self.whitespaceChunks(in: text)
            var chunkBoxes: [Range<String.Index>: CGRect] = [:]
            for chunk in chunks {
                // Whitespace-delimited chunks get reliable boxes from Vision; sub-word ranges often do not.
                if let box = try? candidate.boundingBox(for: chunk) {
                    let r = toPixels(box.boundingBox)
                    let wholeLine = chunks.count > 1 && r.width > lineRect.width * 0.9
                    if !wholeLine, r.width > 0, r.height > 0 { chunkBoxes[chunk] = r }
                }
            }
            var words: [RecognizedWord] = []
            for token in tokens {
                var rect: CGRect?
                if let chunk = chunks.first(where: { $0.contains(token.range.lowerBound) }), let chunkRect = chunkBoxes[chunk] {
                    rect = Self.proportionalRect(for: token.range, in: String(text[chunk]), offsetIn: text, chunk: chunk, chunkRect: chunkRect)
                }
                words.append(RecognizedWord(
                    text: token.text,
                    rect: rect ?? Self.proportionalRect(for: token.range, in: text, lineRect: lineRect)
                ))
            }
            var line = RecognizedLine(text: text, rect: lineRect, words: words, confidence: candidate.confidence)
            if Self.endsWithHyphenatedWord(text), let length = Self.trailingDashLength(in: image, lineRect: lineRect) {
                line.endsWithLongDash = length >= Self.longDashLength
            }
            lines.append(line)
        }
        return lines
    }

    /// Shortest stroke, in line heights, that counts as a dash. Measured on 20 proportional fonts at five sizes:
    /// a hyphen is 0.16–0.39 line heights and an em dash 0.45–1.18. Fixed-width fonts are not separable
    /// (their hyphen and em dash are equally wide), so there a hyphen may count as a dash.
    static let longDashLength: CGFloat = 0.45

    /// True if the line ends in a letter followed by a hyphen ("exam-"), the shape of a word broken across lines.
    static func endsWithHyphenatedWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, Tokenizer.isHyphen(last) else { return false }
        return trimmed.dropLast().last?.isLetter ?? false
    }

    /// Length of the horizontal stroke at the end of a line, in line heights; nil if the line does not end in one.
    ///
    /// Vision returns the same "-" for a hyphen and for an em dash at the end of a line, so the text alone
    /// cannot tell "exam-" + "ple" from "hopes—" + "however". The pixels can: the stroke is measured from the
    /// right end of the line, leftwards, for as long as the ink stays thin and at the same height.
    static func trailingDashLength(in image: CGImage, lineRect: CGRect) -> CGFloat? {
        let h = lineRect.height
        guard h >= 8 else { return nil }
        let region = CGRect(x: lineRect.maxX - h * 1.8, y: lineRect.minY, width: h * 2.1, height: h)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        let w = Int(region.width), rows = Int(region.height)
        guard w >= 4, rows >= 4, let crop = image.cropping(to: region) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * rows)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: rows, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: rows))
            return true
        }
        guard drawn else { return nil }

        // Most of the region is page background, so its median brightness is the background (light or dark theme).
        let background = Int(pixels.sorted()[pixels.count / 2])
        let contrast = pixels.reduce(0) { max($0, abs(Int($1) - background)) }
        guard contrast >= 40 else { return nil }
        let inkLevel = max(12, contrast / 5) // low enough to keep hairline dashes (Didot) in one piece
        /// Top and bottom ink rows of a column, or nil if the column is blank.
        func ink(_ x: Int) -> (top: Int, bottom: Int)? {
            var top = -1, bottom = -1
            for y in 0..<rows where abs(Int(pixels[y * w + x]) - background) >= inkLevel {
                if top < 0 { top = y }
                bottom = y
            }
            return top < 0 ? nil : (top, bottom)
        }

        var x = w - 1
        while x >= 0, ink(x) == nil { x -= 1 } // blank space after the line
        let maxThickness = max(3, Int(h * 0.2))
        let maxDrift = max(2, h * 0.12)
        var length = 0
        var center: CGFloat?
        while x >= 0, let column = ink(x) {
            let mid = CGFloat(column.top + column.bottom) / 2
            guard column.bottom - column.top + 1 <= maxThickness, abs(mid - (center ?? mid)) <= maxDrift else { break }
            if center == nil { center = mid }
            length += 1
            x -= 1
        }
        return length > 0 ? CGFloat(length) / h : nil
    }

    static func whitespaceChunks(in text: String) -> [Range<String.Index>] {
        var chunks: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                if let s = start { chunks.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = text.index(after: i)
        }
        if let s = start { chunks.append(s..<text.endIndex) }
        return chunks
    }

    /// Box of a token inside a chunk ("—however," within "hopes—however,"), by character share of the chunk box.
    static func proportionalRect(for range: Range<String.Index>, in chunkText: String, offsetIn text: String,
                                 chunk: Range<String.Index>, chunkRect: CGRect) -> CGRect {
        let total = max(text.distance(from: chunk.lowerBound, to: chunk.upperBound), 1)
        let start = text.distance(from: chunk.lowerBound, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        if start == 0, length == total { return chunkRect }
        let unit = chunkRect.width / CGFloat(total)
        return CGRect(x: chunkRect.minX + CGFloat(start) * unit, y: chunkRect.minY, width: CGFloat(length) * unit, height: chunkRect.height)
    }

    /// Estimates a word's box by its character offset within the line. Used when Vision
    /// cannot provide a per-word box.
    static func proportionalRect(for range: Range<String.Index>, in text: String, lineRect: CGRect) -> CGRect {
        let total = max(text.count, 1)
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let unit = lineRect.width / CGFloat(total)
        return CGRect(x: lineRect.minX + CGFloat(start) * unit,
                      y: lineRect.minY,
                      width: CGFloat(length) * unit,
                      height: lineRect.height)
    }
}
