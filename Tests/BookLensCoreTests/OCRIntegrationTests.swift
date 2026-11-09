import AppKit
import CoreGraphics
import XCTest
@testable import BookLensCore

/// Renders text like an e-book page, runs real Vision OCR, and checks the word under known points.
final class OCRIntegrationTests: XCTestCase {
    struct Rendered {
        var image: CGImage
        /// Word boxes as laid out by TextKit, in image pixels (top-left origin).
        var boxes: [(String, CGRect)]
    }

    func render(_ text: String, fontName: String, size: CGFloat, width: CGFloat = 900, scale: CGFloat = 2, dark: Bool = false) -> Rendered {
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.5
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.1, alpha: 1), .paragraphStyle: paragraph,
        ])
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let margin: CGFloat = 40
        let pageSize = CGSize(width: width + margin * 2, height: used.height + margin * 2)

        let pw = Int(pageSize.width * scale), ph = Int(pageSize.height * scale)
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(red: 0.98, green: 0.96, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: CGPoint(x: margin, y: margin))
        NSGraphicsContext.restoreGraphicsState()

        var boxes: [(String, CGRect)] = []
        for token in Tokenizer.words(in: text) {
            let nsRange = NSRange(token.range, in: text)
            let glyphs = layout.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            var r = layout.boundingRect(forGlyphRange: glyphs, in: container)
            r.origin.x += margin
            r.origin.y += margin
            boxes.append((token.text, CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)))
        }
        return Rendered(image: ctx.makeImage()!, boxes: boxes)
    }

    static let passage = """
    It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife. However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters. The ephemeral splendour of the evening faded, yet she refused to give up on her obstinate hopes.
    """

    /// Returns the fraction of words whose center hits back to the same word.
    func accuracy(font: String, size: CGFloat, dark: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let rendered = render(Self.passage, fontName: font, size: size, dark: dark)
        let lines = try TextRecognizer().recognize(rendered.image)
        XCTAssertFalse(lines.isEmpty, file: file, line: line)
        var correct = 0, total = 0
        var misses: [String] = []
        for (word, box) in rendered.boxes where word.count >= 3 && box.width > 0 {
            total += 1
            let hit = WordLocator.locate(point: CGPoint(x: box.midX, y: box.midY), in: lines)
            if hit?.word.lowercased() == Tokenizer.normalize(word).lowercased() {
                correct += 1
            } else {
                misses.append("\(word)→\(hit?.word ?? "nil")")
            }
        }
        let acc = Double(correct) / Double(max(total, 1))
        print("OCR accuracy \(font) \(size)pt dark=\(dark): \(correct)/\(total) misses=\(misses)")
        return acc
    }

    func testSerifFontAccuracy() throws {
        XCTAssertGreaterThanOrEqual(try accuracy(font: "Georgia", size: 18), 0.95)
    }

    func testSansFontAccuracy() throws {
        XCTAssertGreaterThanOrEqual(try accuracy(font: "Helvetica Neue", size: 16), 0.95)
    }

    func testSmallFontAccuracy() throws {
        XCTAssertGreaterThanOrEqual(try accuracy(font: "Times New Roman", size: 13), 0.9)
    }

    func testDarkModeAccuracy() throws {
        XCTAssertGreaterThanOrEqual(try accuracy(font: "Georgia", size: 18, dark: true), 0.95)
    }

    func testSentenceFromRealOCR() throws {
        let rendered = render(Self.passage, fontName: "Georgia", size: 18)
        let lines = try TextRecognizer().recognize(rendered.image)
        let box = try XCTUnwrap(rendered.boxes.first { $0.0 == "ephemeral" }).1
        let hit = try XCTUnwrap(WordLocator.locate(point: CGPoint(x: box.midX, y: box.midY), in: lines))
        XCTAssertEqual(hit.word, "ephemeral")
        XCTAssertEqual(hit.sentence, "The ephemeral splendour of the evening faded, yet she refused to give up on her obstinate hopes.")
    }

    func testSweepFromRealOCR() throws {
        let rendered = render(Self.passage, fontName: "Georgia", size: 18)
        let lines = try TextRecognizer().recognize(rendered.image)
        let from = try XCTUnwrap(rendered.boxes.first { $0.0 == "splendour" }).1
        let to = try XCTUnwrap(rendered.boxes.first { $0.0 == "refused" }).1
        let size = CGSize(width: rendered.image.width, height: rendered.image.height)
        let hit = try XCTUnwrap(WordLocator.locateSentence(along: [CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY)],
                                                           in: lines, imageSize: size))
        XCTAssertEqual(hit.text, "The ephemeral splendour of the evening faded, yet she refused to give up on her obstinate hopes.")
        XCTAssertFalse(hit.lineRects.isEmpty)
    }

    func testRecognitionSpeed() throws {
        let rendered = render(Self.passage, fontName: "Georgia", size: 18)
        _ = try TextRecognizer().recognize(rendered.image) // warm up
        let start = Date()
        _ = try TextRecognizer().recognize(rendered.image)
        let elapsed = Date().timeIntervalSince(start)
        print("OCR time: \(Int(elapsed * 1000)) ms for \(rendered.image.width)x\(rendered.image.height)")
        XCTAssertLessThan(elapsed, 1.5)
    }
}

final class WordReaderTests: XCTestCase {
    func testSameAcceptsLineBreakHalves() {
        XCTAssertTrue(WordReader.same("inves", "investigation"))
        XCTAssertTrue(WordReader.same("tigation", "Investigation"))
        XCTAssertFalse(WordReader.same("minds", "acknowledged"))
    }

    func testReaderFindsWordOnRenderedPage() throws {
        let rendered = OCRIntegrationTests().render(OCRIntegrationTests.passage, fontName: "Georgia", size: 16)
        for target in ["acknowledged", "neighbourhood", "obstinate"] {
            let box = try XCTUnwrap(rendered.boxes.first { $0.0 == target }).1
            let hit = try XCTUnwrap(WordReader().read(rendered.image, at: CGPoint(x: box.midX, y: box.midY)))
            XCTAssertEqual(hit.word, target)
        }
    }

    /// Korean text on the page is skipped and English words next to it still read. (Synthetic renders do not
    /// reproduce the "DJIZI" misread; it was checked on a real screenshot, where Hangul came back as "78R", "T5".)
    func testSkipsKoreanText() throws {
        let text = "동사인데 명사라고 표기되어있어. 전체적으로 글씨들이 투명해서 잘 안 보여. 원래 북렌즈 앱만 집중하자.\nWe can do so by having an integer counter that keeps track of the number of full buffers."
        let page = OCRIntegrationTests().render(text, fontName: "Helvetica", size: 18)
        let reader = WordReader()
        for (word, box) in page.boxes {
            let hit = try reader.read(page.image, at: CGPoint(x: box.midX, y: box.midY))
            if word.unicodeScalars.contains(where: { $0.value >= 0xAC00 }) {
                XCTAssertNil(hit, "Korean word \(word) was read as \(hit?.word ?? "")")
            } else if ["counter", "integer", "buffers"].contains(word) {
                XCTAssertEqual(hit?.word, word)
            }
        }
    }
}
