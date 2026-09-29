import AppKit
import BookLensCore
import WebKit

/// Renders e-book-like web pages with WebKit, then checks that OCR + WordLocator find the right word
/// under the center of real word boxes, using the same capture window size as the app.
@MainActor
final class WebPageBench: NSObject, WKNavigationDelegate {
    struct Style {
        var name: String
        var css: String
        var width: CGFloat = 1000
        var height: CGFloat = 820
    }

    static let passages = [
        """
        <p>It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.</p>
        <p>However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters.</p>
        <p>“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?” Mr. Bennet replied that he had not. “But it is,” returned she; “for Mrs. Long has just been here, and she told me all about it.”</p>
        <p>The ephemeral splendour of the evening faded, yet she refused to <em>give up</em> on her obstinate hopes—however <b>preposterous</b> they seemed to the rest of the household.</p>
        """,
        """
        <p>Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.</p>
        <p>It is a way I have of driving off the spleen and regulating the circulation. Whenever I find myself growing grim about the mouth; whenever it is a damp, drizzly November in my soul; whenever I find myself involuntarily pausing before coffin warehouses, and bringing up the rear of every funeral I meet, then, I account it high time to get to sea as soon as I can.</p>
        <p>She bore the pain with remarkable patience, though the surgeon’s instruments were crude and the candlelight flickered <a href="#">unpredictably</a> across the ward.</p>
        """,
    ]

    static let styles: [Style] = [
        Style(name: "ridi-sepia", css: "body{background:#f6f0e3;color:#3b3024;font-family:Georgia,serif;font-size:18px;line-height:1.8;text-align:justify;padding:40px 70px;}"),
        Style(name: "kindle-2col", css: "body{background:#fff;color:#111;font-family:Palatino,serif;font-size:19px;line-height:1.6;column-count:2;column-gap:60px;padding:40px 50px;text-align:justify;hyphens:auto;-webkit-hyphens:auto;}", width: 1280),
        Style(name: "dark", css: "body{background:#121212;color:#d8d8d8;font-family:'Iowan Old Style',serif;font-size:17px;line-height:1.7;padding:40px 70px;}"),
        Style(name: "small-sans", css: "body{background:#fff;color:#222;font-family:'Helvetica Neue',sans-serif;font-size:13px;line-height:1.5;padding:30px;max-width:520px;text-align:justify;hyphens:auto;-webkit-hyphens:auto;}", width: 600),
        Style(name: "large-times", css: "body{background:#fdfdf8;color:#000;font-family:'Times New Roman',serif;font-size:24px;line-height:1.5;padding:40px 60px;} a{color:#0645ad}", width: 1100, height: 1400),
    ]

    /// Simulate a non-Retina (1x) display: render at 1x, then upscale to 2x like the app's capture does.
    var simulateNonRetina = false

    private let webView: WKWebView
    private let window: NSWindow
    private var navigationContinuation: CheckedContinuation<Void, Never>?

    override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 820))
        window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        window.orderBack(nil)
        webView.navigationDelegate = self
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationContinuation?.resume()
            self.navigationContinuation = nil
        }
    }

    struct WordBox { var text: String; var rect: CGRect }

    func load(style: Style, passage: String) async -> (CGImage, [WordBox])? {
        window.setContentSize(CGSize(width: style.width, height: style.height))
        webView.frame = CGRect(x: 0, y: 0, width: style.width, height: style.height)
        let html = "<!doctype html><html lang=en><head><meta charset=utf-8><style>html,body{margin:0}\(style.css)</style></head><body>\(passage)</body></html>"
        await withCheckedContinuation { c in
            navigationContinuation = c
            webView.loadHTMLString(html, baseURL: nil)
        }
        try? await Task.sleep(for: .milliseconds(300))
        _ = try? await webView.evaluateJavaScript("document.fonts.ready.then(() => true)")
        try? await Task.sleep(for: .milliseconds(200))
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(simulateNonRetina ? style.width / 2 : style.width)) // points; Retina gives 2x pixels
        guard let snapshot = try? await webView.takeSnapshot(configuration: config),
              var cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if simulateNonRetina {
            let w = Int(style.width * 2), h = cg.height * w / cg.width
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            cg = ctx.makeImage()!
        }
        let js = """
        (() => {
          const out = [];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const re = /[A-Za-z0-9]+(?:[’'-][A-Za-z0-9]+)*/g;
          let node;
          while ((node = walker.nextNode())) {
            let m;
            while ((m = re.exec(node.data))) {
              const r = document.createRange();
              r.setStart(node, m.index); r.setEnd(node, m.index + m[0].length);
              const rects = r.getClientRects();
              if (rects.length === 1) out.push([m[0], rects[0].left, rects[0].top, rects[0].width, rects[0].height]);
            }
          }
          return JSON.stringify(out);
        })()
        """
        guard let json = try? await webView.evaluateJavaScript(js) as? String,
              let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]] else { return nil }
        let scale = CGFloat(cg.width) / style.width
        let boxes = raw.compactMap { a -> WordBox? in
            guard let t = a[0] as? String, let x = a[1] as? Double, let y = a[2] as? Double, let w = a[3] as? Double, let h = a[4] as? Double else { return nil }
            return WordBox(text: t, rect: CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale))
        }
        return (cg, boxes.filter { $0.rect.maxY < CGFloat(cg.height) })
    }

    static func crop(_ image: CGImage, around p: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat) -> (CGImage, CGPoint)? {
        let r = CGRect(x: p.x - halfWidth, y: p.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard let c = image.cropping(to: r) else { return nil }
        return (c, CGPoint(x: p.x - r.minX, y: p.y - r.minY))
    }

    /// End-to-end: render → crop like the app → OCR → locate → local model definition.
    func runEndToEnd(model: String, targets: [String]) async {
        let reader = WordReader()
        let provider = OllamaMeaningProvider(model: model)
        for style in [Self.styles[0], Self.styles[1], Self.styles[2]] {
            for passage in Self.passages {
                guard let (image, boxes) = await load(style: style, passage: passage) else { continue }
                for target in targets {
                    guard let box = boxes.first(where: { $0.text == target }) else { continue }
                    let center = CGPoint(x: box.rect.midX, y: box.rect.midY)
                    guard let (crop, local) = Self.crop(image, around: center, halfWidth: CGFloat(image.width), halfHeight: 400) else { continue }
                    let t0 = Date()
                    guard let hit = try? reader.read(crop, at: local) else { print("\(style.name) \(target): NO HIT"); continue }
                    let t1 = Date()
                    var firstMeaning: Date?
                    var def = WordDefinition()
                    do {
                        for try await e in provider.lookup(LookupRequest(word: hit.word, sentence: hit.sentence, context: hit.context)) {
                            switch e {
                            case .partial(let d): if firstMeaning == nil, !d.meaning.isEmpty { firstMeaning = Date() }
                            case .complete(let d): def = d
                            }
                        }
                    } catch { print("ERR \(error)") }
                    let t2 = Date()
                    print(String(format: "[%@] %@ OCR %.0fms, meaning %.2fs, total %.2fs", style.name, hit.word, t1.timeIntervalSince(t0) * 1000,
                                 (firstMeaning ?? t2).timeIntervalSince(t0), t2.timeIntervalSince(t0)))
                    print("   sentence: \(hit.sentence)")
                    print("   → \(def.expression) [\(def.partOfSpeech)] \(def.meaning) | \(def.explanation) | \(def.otherMeanings.joined(separator: ", "))")
                }
            }
        }
    }

    func run(samplesPerPage: Int, dumpDir: URL?) async -> Bool {
        let reader = WordReader()
        var totalHits = 0, totalCorrect = 0
        var ocrTimes: [Double] = []
        var allOK = true
        for style in Self.styles {
            for (pi, passage) in Self.passages.enumerated() {
                guard let (image, boxes) = await load(style: style, passage: passage) else {
                    print("\(style.name)#\(pi): render failed")
                    allOK = false
                    continue
                }
                if let dumpDir {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dumpDir.appendingPathComponent("\(style.name)-\(pi).png"))
                }
                let candidates = boxes.filter { $0.text.count >= 3 && Tokenizer.isLookupCandidate($0.text) }
                let stride = max(1, candidates.count / samplesPerPage)
                var correct = 0, total = 0
                var misses: [String] = []
                for (i, box) in candidates.enumerated() where i % stride == 0 {
                    let center = CGPoint(x: box.rect.midX, y: box.rect.midY)
                    // Same capture band as the app: full window width × ±200 points at 2x.
                    guard let (crop, local) = Self.crop(image, around: center, halfWidth: CGFloat(image.width), halfHeight: 400) else { continue }
                    let t0 = Date()
                    let hit = try? reader.read(crop, at: local)
                    ocrTimes.append(Date().timeIntervalSince(t0))
                    total += 1
                    let expected = Tokenizer.normalize(box.text).lowercased()
                    if let hit, hit.word.lowercased() == expected {
                        correct += 1
                        if !hit.sentence.lowercased().contains(expected) { misses.append("sentence?\(expected)") }
                    } else {
                        misses.append("\(box.text)→\(hit?.word ?? "nil")@\(Int(center.x)),\(Int(center.y))")
                    }
                }
                totalHits += total
                totalCorrect += correct
                print(String(format: "%-12@ #%d  %3d/%3d  %@", style.name as NSString, pi, correct, total, misses.prefix(8).joined(separator: " ")))
            }
        }
        let acc = Double(totalCorrect) / Double(max(totalHits, 1))
        ocrTimes.sort()
        let median = ocrTimes.isEmpty ? 0 : ocrTimes[ocrTimes.count / 2]
        let p95 = ocrTimes.isEmpty ? 0 : ocrTimes[min(ocrTimes.count - 1, Int(Double(ocrTimes.count) * 0.95))]
        print(String(format: "TOTAL %d/%d = %.1f%%   OCR median %.0fms p95 %.0fms", totalCorrect, totalHits, acc * 100, median * 1000, p95 * 1000))
        return allOK && acc >= 0.95
    }
}
