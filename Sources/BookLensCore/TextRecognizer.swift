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
            lines.append(RecognizedLine(text: text, rect: lineRect, words: words, confidence: candidate.confidence))
        }
        return lines
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
