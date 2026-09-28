import CoreGraphics
import Foundation

/// A single word recognized on screen. `rect` is in image pixel coordinates (origin top-left).
public struct RecognizedWord: Equatable, Sendable {
    public var text: String
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// A line of text recognized on screen, split into words. `rect` is in image pixel coordinates (origin top-left).
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    public var words: [RecognizedWord]
    public var confidence: Float

    public init(text: String, rect: CGRect, words: [RecognizedWord], confidence: Float = 1) {
        self.text = text
        self.rect = rect
        self.words = words
        self.confidence = confidence
    }
}

/// Result of locating the word under the cursor.
public struct WordHit: Equatable, Sendable {
    /// The word as it appears on screen, with surrounding punctuation stripped.
    public var word: String
    /// The word's bounding box in image pixel coordinates (origin top-left).
    public var rect: CGRect
    /// The sentence containing the word (best effort, may be truncated at capture edges).
    public var sentence: String
    /// A wider window of surrounding text for disambiguation.
    public var context: String

    public init(word: String, rect: CGRect, sentence: String, context: String) {
        self.word = word
        self.rect = rect
        self.sentence = sentence
        self.context = context
    }
}
