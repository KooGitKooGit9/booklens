import AppKit
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
]

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
case "web":
    let dump = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil
    if let dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
    _ = NSApplication.shared
    let ok = await MainActor.run { WebPageBench() }.run(samplesPerPage: 40, dumpDir: dump)
    exit(ok ? 0 : 1)
default:
    print("usage: booklens-bench models [model ...] | web [dump-dir]")
}
