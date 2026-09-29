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

    public func read(_ image: CGImage, at point: CGPoint) throws -> WordHit? {
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
        let h = rect.height
        let strip = CGRect(x: rect.minX - h * 8, y: rect.minY - h * 0.35, width: rect.width + h * 16, height: h * 1.7)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !strip.isEmpty, let cropped = image.cropping(to: strip) else { return nil }
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
