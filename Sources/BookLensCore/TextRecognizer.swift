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
            var words: [RecognizedWord] = []
            for token in tokens {
                var rect: CGRect?
                if let box = try? candidate.boundingBox(for: token.range) {
                    let r = toPixels(box.boundingBox)
                    // Vision occasionally returns the whole line box for a sub-range; reject that.
                    let wholeLine = tokens.count > 1 && r.width > lineRect.width * 0.9
                    if !wholeLine, r.width > 0, r.height > 0 {
                        rect = r
                    }
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
