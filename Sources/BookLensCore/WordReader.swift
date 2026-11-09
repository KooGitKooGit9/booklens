import CoreGraphics
import Foundation

/// OCR + word location with a verification pass.
///
/// Vision occasionally pairs a line's text with another line's box (seen on some crop heights),
/// which would show the wrong word. After locating the word in the full capture, a thin strip
/// around it is recognized again; if the two disagree, the capture is re-recognized with slightly
/// different edges, and as a last resort the strip's word is used.
public struct WordReader: Sendable {
    public var recognizer: TextRecognizer

    /// Language correction is off: it costs ~110 ms per lookup and made no difference to word accuracy
    /// in the WebKit bench (496/496 at 2x, 492 vs 493/496 at 1x).
    public init(recognizer: TextRecognizer = TextRecognizer(usesLanguageCorrection: false)) {
        self.recognizer = recognizer
    }

    /// Reads Hangul as Hangul. Not used for the main pass: with Korean first, English accuracy dropped
    /// (490 vs 496/497 in the WebKit bench) and OCR got slower.
    var koreanRecognizer = TextRecognizer(languages: ["ko-KR", "en-US"], usesLanguageCorrection: false)

    /// The English recognizer reads Hangul as Latin look-alikes ("명사라고" → "DJIZI") with low confidence
    /// (0.3, against 1.0 for real English text). Such words are re-read with Korean enabled and skipped if
    /// they turn out to be Hangul.
    static let lowConfidence: Float = 0.5

    public func read(_ image: CGImage, at point: CGPoint) throws -> WordHit? {
        guard let hit = try readWord(image, at: point) else { return nil }
        if hit.confidence < Self.lowConfidence, try isHangul(image, point: point, around: hit.rect) { return nil }
        return hit
    }

    /// True if the text under `point` is Korean when read with the Korean recognizer.
    func isHangul(_ image: CGImage, point: CGPoint, around rect: CGRect) throws -> Bool {
        guard let (cropped, strip) = Self.strip(of: image, around: rect) else { return false }
        let local = CGPoint(x: point.x - strip.minX, y: point.y - strip.minY)
        return try koreanRecognizer.recognize(cropped).contains { line in
            line.rect.insetBy(dx: -4, dy: -4).contains(local)
                && line.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
        }
    }

    static func strip(of image: CGImage, around rect: CGRect) -> (CGImage, CGRect)? {
        let h = rect.height
        let strip = CGRect(x: rect.minX - h * 8, y: rect.minY - h * 0.35, width: rect.width + h * 16, height: h * 1.7)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !strip.isEmpty, let cropped = image.cropping(to: strip) else { return nil }
        return (cropped, strip)
    }

    func readWord(_ image: CGImage, at point: CGPoint) throws -> WordHit? {
        let size = CGSize(width: image.width, height: image.height)
        let lines = try recognizer.recognize(image)
        guard let hit = WordLocator.locate(point: point, in: lines, imageSize: size) else { return nil }
        guard let stripHit = try verify(image, point: point, around: hit.rect) else { return hit }
        if Self.same(stripHit.word, hit.word) { return hit }

        // Disagreement: re-recognize with the band's top and bottom edges moved in a little.
        let inset = min(CGFloat(24), size.height / 8)
        let retryRect = CGRect(x: 0, y: inset, width: size.width, height: size.height - inset * 2)
        if retryRect.contains(point), let retryImage = image.cropping(to: retryRect.integral) {
            let local = CGPoint(x: point.x - retryRect.minX, y: point.y - retryRect.minY)
            let retryLines = try recognizer.recognize(retryImage)
            if var retry = WordLocator.locate(point: local, in: retryLines, imageSize: retryRect.size), Self.same(retry.word, stripHit.word) {
                retry.rect = retry.rect.offsetBy(dx: retryRect.minX, dy: retryRect.minY)
                return retry
            }
        }
        return stripHit
    }

    /// Recognizes a thin strip around the word; returns what it finds under `point` in image coordinates.
    func verify(_ image: CGImage, point: CGPoint, around rect: CGRect) throws -> WordHit? {
        guard let (cropped, strip) = Self.strip(of: image, around: rect) else { return nil }
        let lines = try recognizer.recognize(cropped)
        guard var hit = WordLocator.locate(point: CGPoint(x: point.x - strip.minX, y: point.y - strip.minY), in: lines) else { return nil }
        hit.rect = hit.rect.offsetBy(dx: strip.minX, dy: strip.minY)
        return hit
    }

    /// Equal, or one is the on-screen half of a word joined across a line break ("inves" / "investigation").
    static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        return short.count >= 2 && (long.hasPrefix(short) || long.hasSuffix(short))
    }
}
