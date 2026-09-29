import CoreGraphics
import XCTest
@testable import BookLensCore

/// Builds an OCR line with evenly spaced characters, like a monospace renderer would.
func makeLine(_ text: String, y: CGFloat, x: CGFloat = 0, charWidth: CGFloat = 10, height: CGFloat = 20) -> RecognizedLine {
    let words = Tokenizer.words(in: text).map { tok -> RecognizedWord in
        let start = CGFloat(text.distance(from: text.startIndex, to: tok.range.lowerBound))
        return RecognizedWord(text: tok.text, rect: CGRect(x: x + start * charWidth, y: y, width: CGFloat(tok.text.count) * charWidth, height: height))
    }
    return RecognizedLine(text: text, rect: CGRect(x: x, y: y, width: CGFloat(text.count) * charWidth, height: height), words: words)
}

/// Center point of the n-th occurrence of `word` in a line built by `makeLine`.
func center(of word: String, in line: RecognizedLine, occurrence: Int = 0) -> CGPoint {
    let r = line.words.filter { $0.text == word }[occurrence].rect
    return CGPoint(x: r.midX, y: r.midY)
}

final class TokenizerTests: XCTestCase {
    func testSplitsWordsAndKeepsContractions() {
        let words = Tokenizer.words(in: "\"Don’t go,\" she said—well-known facts (1999).").map(\.text)
        XCTAssertEqual(words, ["Don’t", "go", "she", "said", "well-known", "facts", "1999"])
    }

    func testKeepsLineFinalHyphen() {
        XCTAssertEqual(Tokenizer.words(in: "an exam-").map(\.text), ["an", "exam-"])
        XCTAssertEqual(Tokenizer.words(in: "a - b").map(\.text), ["a", "b"])
    }

    func testLookupCandidate() {
        XCTAssertTrue(Tokenizer.isLookupCandidate("word"))
        XCTAssertFalse(Tokenizer.isLookupCandidate("1999"))
        XCTAssertFalse(Tokenizer.isLookupCandidate("한국어"))
    }
}

final class WordLocatorTests: XCTestCase {
    let page = [
        makeLine("It was the best of times. The ephemeral glow of", y: 0),
        makeLine("the lamp faded, and Mr. Holmes gave up on the", y: 30),
        makeLine("inves-", y: 60),
        makeLine("tigation entirely. Nobody noticed.", y: 90),
    ]

    func testFindsWordUnderPoint() throws {
        let hit = try XCTUnwrap(WordLocator.locate(point: center(of: "ephemeral", in: page[0]), in: page))
        XCTAssertEqual(hit.word, "ephemeral")
        XCTAssertEqual(hit.sentence, "The ephemeral glow of the lamp faded, and Mr. Holmes gave up on the investigation entirely.")
    }

    func testSentenceSpansLinesAndSkipsAbbreviation() throws {
        let hit = try XCTUnwrap(WordLocator.locate(point: center(of: "gave", in: page[1]), in: page))
        XCTAssertEqual(hit.word, "gave")
        XCTAssertTrue(hit.sentence.hasPrefix("The ephemeral glow"))
        XCTAssertTrue(hit.context.contains("best of times"))
        XCTAssertTrue(hit.context.contains("Nobody noticed."))
    }

    func testJoinsHyphenatedWordFromEitherHalf() throws {
        let first = try XCTUnwrap(WordLocator.locate(point: center(of: "inves-", in: page[2]), in: page))
        XCTAssertEqual(first.word, "investigation")
        let second = try XCTUnwrap(WordLocator.locate(point: center(of: "tigation", in: page[3]), in: page))
        XCTAssertEqual(second.word, "investigation")
    }

    func testPointInMarginReturnsNil() {
        XCTAssertNil(WordLocator.locate(point: CGPoint(x: 5, y: 200), in: page))
        XCTAssertNil(WordLocator.locate(point: CGPoint(x: 2000, y: 10), in: page))
    }

    func testPointSlightlyBetweenWordsPicksNearest() throws {
        let line = page[0]
        let best = line.words.first { $0.text == "best" }!.rect
        let hit = try XCTUnwrap(WordLocator.locate(point: CGPoint(x: best.maxX + 3, y: best.midY), in: page))
        XCTAssertEqual(hit.word, "best")
    }

    func testTwoColumnsDoNotMix() throws {
        let left = [makeLine("Left column talks about apples.", y: 0), makeLine("More apples here.", y: 30)]
        let right = [makeLine("Right column mentions oranges.", y: 0, x: 600), makeLine("More oranges there.", y: 30, x: 600)]
        let lines = left + right
        let hit = try XCTUnwrap(WordLocator.locate(point: center(of: "oranges", in: right[1]), in: lines))
        XCTAssertEqual(hit.sentence, "More oranges there.")
        XCTAssertFalse(hit.context.contains("apples"))
    }

    func testDashReadAsHyphenPicksPartUnderCursor() throws {
        let lines = [makeLine("She kept her hopes-however slim.", y: 0)]
        let word = lines[0].words.first { $0.text == "hopes-however" }!.rect
        let left = try XCTUnwrap(WordLocator.locate(point: CGPoint(x: word.minX + 10, y: word.midY), in: lines))
        XCTAssertEqual(left.word, "hopes")
        XCTAssertLessThan(left.rect.width, word.width)
        let right = try XCTUnwrap(WordLocator.locate(point: CGPoint(x: word.maxX - 10, y: word.midY), in: lines))
        XCTAssertEqual(right.word, "however")
        XCTAssertEqual(right.sentence, "She kept her hopes-however slim.")
    }

    func testIgnoresNumbers() {
        let lines = [makeLine("Chapter 12", y: 0)]
        XCTAssertNil(WordLocator.locate(point: center(of: "12", in: lines[0]), in: lines))
    }

    func testQuotedSentence() throws {
        let lines = [makeLine("He smiled. \"You are quite obstinate,\" she replied. Then silence.", y: 0)]
        let hit = try XCTUnwrap(WordLocator.locate(point: center(of: "obstinate", in: lines[0]), in: lines))
        XCTAssertEqual(hit.sentence, "\"You are quite obstinate,\" she replied.")
    }

    func testVeryLongSentenceIsTrimmedAroundWord() throws {
        let long = (0..<120).map { "w\($0)" }.joined(separator: " ")
        let lines = [makeLine(long + " target " + long, y: 0, charWidth: 2)]
        let hit = try XCTUnwrap(WordLocator.locate(point: center(of: "target", in: lines[0]), in: lines))
        XCTAssertTrue(hit.sentence.contains("target"))
        XCTAssertLessThanOrEqual(hit.sentence.count, 440)
    }
}

final class PartialJSONTests: XCTestCase {
    func testParsesCompleteObject() {
        let json = #"{"expression":"give up","lemma":"give","pos":"구동사","meaning":"포기하다","ipa":"/ɡɪv ʌp/","explanation":"설명","other_meanings":["주다","\"제공\"하다"]}"#
        let d = WordDefinition.fromModelJSON(json, source: "t")
        XCTAssertEqual(d.expression, "give up")
        XCTAssertEqual(d.meaning, "포기하다")
        XCTAssertEqual(d.otherMeanings, ["주다", "\"제공\"하다"])
    }

    func testParsesTruncatedStream() {
        let d = WordDefinition.fromModelJSON(#"{"expression":"bank","lemma":"bank","pos":"명사","meaning":"강 기"#, source: "t")
        XCTAssertEqual(d.lemma, "bank")
        XCTAssertEqual(d.meaning, "강 기")
        XCTAssertEqual(d.ipa, "")
    }

    func testTruncatedArrayKeepsClosedItems() {
        let d = WordDefinition.fromModelJSON(#"{"meaning":"x","other_meanings":["a","b","c"#, source: "t")
        XCTAssertEqual(d.otherMeanings, ["a", "b"])
    }

    func testIgnoresCodeFenceAndEscapes() {
        let d = WordDefinition.fromModelJSON("```json\n{\"meaning\":\"\\uD55C line\\nnext\", \"n\": 3, \"lemma\": \"z\"}", source: "t")
        XCTAssertEqual(d.lemma, "z")
        XCTAssertTrue(d.meaning.hasSuffix("line\nnext"))
    }

    func testCleanedRemovesDuplicateMeanings() {
        let d = WordDefinition(meaning: "인정하다, 인정받다", explanation: "인정하다, 인정받다",
                               otherMeanings: ["인정하다", "알리다", "알리다 ", "감사하다", "(사실을) 인정받다", "고백하다"]).cleaned()
        XCTAssertEqual(d.otherMeanings, ["알리다", "감사하다", "고백하다"])
        XCTAssertEqual(d.explanation, "")
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(WordDefinition.fromModelJSON("", source: "t").isEmpty)
        XCTAssertTrue(WordDefinition.fromModelJSON("no json here", source: "t").isEmpty)
    }
}

final class VocabStoreTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testRecordDeduplicatesAndPersists() {
        let store = VocabStore(fileURL: url)
        let def = WordDefinition(expression: "give up", lemma: "give", meaning: "포기하다")
        store.record(word: "gave", definition: def, sentence: "He gave up.", sourceTitle: "Book A")
        store.record(word: "giving", definition: def, sentence: "Stop giving up.", sourceTitle: "Book B")
        store.record(word: "bank", definition: WordDefinition(expression: "bank", meaning: "은행"), sentence: "s", sourceTitle: "")
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].word, "bank")
        XCTAssertEqual(store.entries[1].lookupCount, 2)
        XCTAssertEqual(store.entries[1].sentence, "Stop giving up.")

        let reloaded = VocabStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.key), ["bank", "give up"])
        reloaded.remove(ids: [reloaded.entries[0].id])
        XCTAssertEqual(VocabStore(fileURL: url).entries.count, 1)
    }

    func testCSVEscaping() {
        let store = VocabStore(fileURL: url)
        store.record(word: "quote", definition: WordDefinition(expression: "quote", partOfSpeech: "명사", meaning: "인용, \"문구\""),
                     sentence: "A \"quote\", here.", sourceTitle: "T")
        let csv = store.csv()
        XCTAssertTrue(csv.hasPrefix("Front,Back,Sentence,Source,Lookups,Added\n"))
        XCTAssertTrue(csv.contains("quote,\"명사 인용, \"\"문구\"\"\",\"A \"\"quote\"\", here.\",T,1,"))
    }

    func testCorruptFileIsBackedUpNotLost() throws {
        try "garbage".write(to: url, atomically: true, encoding: .utf8)
        let store = VocabStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backups = siblings.filter { $0.lastPathComponent.hasPrefix(url.deletingPathExtension().lastPathComponent + ".corrupt") }
        XCTAssertEqual(backups.count, 1)
        backups.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

final class ProviderTests: XCTestCase {
    func testMockProviderStreamsPartialThenComplete() async throws {
        var events: [LookupEvent] = []
        for try await e in MockMeaningProvider().lookup(LookupRequest(word: "Ephemeral", sentence: "s")) { events.append(e) }
        XCTAssertEqual(events.count, 2)
        guard case .complete(let d) = events.last else { return XCTFail() }
        XCTAssertEqual(d.meaning, "잠깐 동안의, 덧없는")
    }

    struct FailingProvider: MeaningProvider {
        func lookup(_ request: LookupRequest) -> AsyncThrowingStream<LookupEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: OllamaClient.OllamaError.notRunning) }
        }
    }

    func testFallbackUsedWhenPrimaryFails() async throws {
        let provider = FallbackMeaningProvider(primary: FailingProvider(), fallback: MockMeaningProvider())
        var last: WordDefinition?
        for try await e in provider.lookup(LookupRequest(word: "bank", sentence: "s")) {
            if case .complete(let d) = e { last = d }
        }
        XCTAssertEqual(last?.source, "mock")
    }

    func testOllamaNotRunningThrowsQuickly() async {
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        let provider = OllamaMeaningProvider(client: client, model: "x")
        do {
            for try await _ in provider.lookup(LookupRequest(word: "a", sentence: "b")) {}
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? OllamaClient.OllamaError, .notRunning)
        }
    }

    func testSystemDictionaryParse() {
        let text = "run | rʌn | verb (runs, running; past ran) [no object] 1 move at a speed faster than a walk: she ran to the door. 2 pass or cause to pass quickly: he ran his fingers through his hair."
        let d = SystemDictionaryProvider.parse(word: "ran", text: text)
        XCTAssertEqual(d.lemma, "run")
        XCTAssertEqual(d.ipa, "/rʌn/")
        XCTAssertEqual(d.partOfSpeech, "동사")
        XCTAssertEqual(d.meaning, "move at a speed faster than a walk")
        XCTAssertEqual(d.otherMeanings, ["pass or cause to pass quickly"])
    }

    func testLookupCacheEvicts() {
        let cache = LookupCache(capacity: 2)
        let a = LookupRequest(word: "a", sentence: ""), b = LookupRequest(word: "b", sentence: ""), c = LookupRequest(word: "c", sentence: "")
        cache.set(a, WordDefinition(meaning: "A"))
        cache.set(b, WordDefinition(meaning: "B"))
        _ = cache.get(a)
        cache.set(c, WordDefinition(meaning: "C"))
        XCTAssertNotNil(cache.get(a))
        XCTAssertNil(cache.get(b))
    }
}

extension OllamaClient.OllamaError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.notRunning, .notRunning): return true
        case (.http(let a, let b), .http(let c, let d)): return a == c && b == d
        case (.server(let a), .server(let b)): return a == b
        default: return false
        }
    }
}

final class CapturedRegionTests: XCTestCase {
    func testRoundTripBetweenScreenAndImageCoordinates() {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A 200×100 pt band whose bottom-left corner is at (100, 500) in Cocoa coordinates, captured at 2x.
        let region = CapturedRegion(image: ctx.makeImage()!, frame: CGRect(x: 100, y: 500, width: 200, height: 100), scale: 2)
        XCTAssertEqual(region.imagePoint(for: CGPoint(x: 100, y: 600)), CGPoint(x: 0, y: 0)) // top-left
        XCTAssertEqual(region.imagePoint(for: CGPoint(x: 300, y: 500)), CGPoint(x: 400, y: 200)) // bottom-right
        let wordInImage = CGRect(x: 40, y: 20, width: 60, height: 30)
        let onScreen = region.globalRect(for: wordInImage)
        XCTAssertEqual(onScreen, CGRect(x: 120, y: 575, width: 30, height: 15))
        XCTAssertEqual(region.imagePoint(for: CGPoint(x: onScreen.minX, y: onScreen.maxY)), CGPoint(x: 40, y: 20))
    }
}
