import AppKit
import ImageIO
import BookLensCore
import Foundation

// Developer tool: compares local models on latency and output for typical e-book lookups.
// Usage: booklens-bench models [model ...]

let cases: [LookupRequest] = [
    LookupRequest(word: "bank", sentence: "She sat on the bank and watched the river drift past."),
    LookupRequest(word: "gave", sentence: "After three failed attempts, he finally gave up on the idea."),
    LookupRequest(word: "ephemeral", sentence: "Fame in the age of social media is ephemeral."),
    LookupRequest(word: "run", sentence: "She was asked to run the company after her father retired."),
    LookupRequest(word: "fortune", sentence: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."),
    LookupRequest(word: "bore", sentence: "She bore the pain with remarkable patience."),
    LookupRequest(word: "hand", sentence: "On the other hand, the plan could save us a lot of money."),
    LookupRequest(word: "fine", sentence: "He had to pay a fine for parking in the wrong place."),
    LookupRequest(word: "wound", sentence: "He wound the old clock before going to bed."),
    LookupRequest(word: "minute", sentence: "The scientist examined the minute differences between the two samples."),
    LookupRequest(word: "content", sentence: "She seemed content with her quiet life in the village."),
    LookupRequest(word: "novel", sentence: "The committee welcomed his novel approach to the problem."),
    LookupRequest(word: "fork", sentence: "The parent process may fork a child process and wait for it to finish."),
    LookupRequest(word: "use", sentence: "Simple user interface, small memory use."),
    LookupRequest(word: "counter", sentence: "We can do so by having an integer counter that keeps track of the number of full buffers."),
    LookupRequest(word: "soongongdan", sentence: "soongongdan_ad"),
].map { c in
    // Like the app: attach the English–Korean dictionary senses when the word is in the dictionary.
    var c = c
    c.dictionary = KoreanDictionary.shared.lookup(c.word)
    return c
}

func runModels(_ models: [String]) async {
    let client = OllamaClient()
    for model in models {
        print("\n=== \(model) ===")
        do { try await client.warmUp(model: model) } catch { print("warm-up failed: \(error)"); continue }
        var totals: [Double] = []
        var firsts: [Double] = []
        for c in cases {
            let start = Date()
            var firstMeaning: Double?
            var final: WordDefinition?
            do {
                for try await event in OllamaMeaningProvider(client: client, model: model).lookup(c) {
                    switch event {
                    case .partial(let d):
                        if firstMeaning == nil, d.meaning.count >= 2 { firstMeaning = Date().timeIntervalSince(start) }
                    case .complete(let d):
                        final = d
                    }
                }
            } catch {
                print("ERROR \(c.word): \(error)")
                continue
            }
            let total = Date().timeIntervalSince(start)
            totals.append(total)
            firsts.append(firstMeaning ?? total)
            let d = final ?? WordDefinition()
            print(String(format: "[%.2fs/%.2fs] %@ → %@ [%@] (%@) %@ | %@ | %@ | %@",
                         firstMeaning ?? total, total, c.word, d.expression, d.lemma, d.partOfSpeech, d.ipa, d.meaning,
                         d.explanation, d.otherMeanings.joined(separator: ", ")))
        }
        if !totals.isEmpty {
            print(String(format: "avg first-meaning %.2fs, avg total %.2fs", firsts.reduce(0, +) / Double(firsts.count),
                         totals.reduce(0, +) / Double(totals.count)))
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "models":
    let models = args.count > 1 ? Array(args.dropFirst()) : ["qwen2.5:7b-instruct", "exaone3.5:2.4b", "gemma3:4b"]
    await runModels(models)
case "web", "web1x":
    let nonRetina = args.first == "web1x"
    let dump = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil
    if let dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
    _ = NSApplication.shared
    let bench = await MainActor.run { () -> WebPageBench in
        let b = WebPageBench()
        b.simulateNonRetina = nonRetina
        return b
    }
    let ok = await bench.run(samplesPerPage: 40, dumpDir: dump)
    exit(ok ? 0 : 1)
case "probe":
    // probe <image> <x> <y>: crop a band like the app, OCR, and show lines + hit.
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    let (crop, local) = await MainActor.run { WebPageBench.crop(image, around: p, halfWidth: CGFloat(image.width), halfHeight: 400)! }
    let lines = try TextRecognizer().recognize(crop)
    for l in lines { print(Int(l.rect.minY), Int(l.rect.height), l.words.prefix(4).map { "\($0.text)@\(Int($0.rect.minX))-\(Int($0.rect.maxX)),\(Int($0.rect.minY))" }) }
    print("local", local, "hit:", WordLocator.locate(point: local, in: lines, imageSize: CGSize(width: crop.width, height: crop.height)) as Any)
case "e2e":
    _ = NSApplication.shared
    let model = args.count > 1 ? args[1] : "qwen3:8b"
    await MainActor.run { WebPageBench() }.runEndToEnd(model: model, targets: ["ephemeral", "obstinate", "acknowledged", "drizzly", "spleen", "bore", "unpredictably", "let", "give"])
case "dict":
    // dict <word ...>: show what the English–Korean dictionary gives for each word.
    for w in args.dropFirst() {
        let start = Date()
        let e = KoreanDictionary.shared.lookup(w)
        print(String(format: "%@ (%.0fms) → %@ %@", w, Date().timeIntervalSince(start) * 1000, e?.headword ?? "nil", e?.ipa ?? ""))
        for g in e?.groups ?? [] { print("   \(g.pos): \(g.glosses.joined(separator: " · "))") }
    }
default:
    print("usage: booklens-bench models [model ...] | web [dump-dir]")
}
