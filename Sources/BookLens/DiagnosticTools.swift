import AppKit
import BookLensCore
import SwiftUI

enum DiagnosticTools {
    /// Runs the full lookup pipeline on an image file and prints the result as JSON.
    static func pipeline(imagePath: String, x: Double, y: Double, model: String) async -> Int32 {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            print("{\"error\":\"cannot read image\"}")
            return 1
        }
        let t0 = Date()
        let found: WordHit?
        do { found = try WordReader().read(image, at: CGPoint(x: x, y: y)) } catch {
            print("{\"error\":\"ocr failed\"}")
            return 1
        }
        let t1 = Date()
        guard let hit = found else {
            print("{\"error\":\"no word\",\"ocr_ms\":\(Int(t1.timeIntervalSince(t0) * 1000))}")
            return 2
        }
        let request = LookupRequest(word: hit.word, sentence: hit.sentence, context: hit.context)
        let provider = FallbackMeaningProvider(primary: OllamaMeaningProvider(model: model), fallback: SystemDictionaryProvider())
        var definition = WordDefinition()
        var firstMeaning: Date?
        do {
            for try await event in provider.lookup(request) {
                switch event {
                case .partial(let d):
                    if firstMeaning == nil, !d.meaning.isEmpty { firstMeaning = Date() }
                case .complete(let d): definition = d
                }
            }
        } catch {
            print("{\"error\":\"\(error.localizedDescription)\"}")
            return 3
        }
        let t2 = Date()
        let output: [String: Any] = [
            "word": hit.word,
            "sentence": hit.sentence,
            "rect": [hit.rect.minX, hit.rect.minY, hit.rect.width, hit.rect.height],
            "ocr_ms": Int(t1.timeIntervalSince(t0) * 1000),
            "first_meaning_ms": Int((firstMeaning ?? t2).timeIntervalSince(t1) * 1000),
            "total_ms": Int(t2.timeIntervalSince(t0) * 1000),
            "expression": definition.expression,
            "lemma": definition.lemma,
            "pos": definition.partOfSpeech,
            "meaning": definition.meaning,
            "ipa": definition.ipa,
            "explanation": definition.explanation,
            "other_meanings": definition.otherMeanings,
            "source": definition.source,
        ]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(data: data, encoding: .utf8)!)
        return 0
    }

    @MainActor
    static func renderWindows(to directory: URL, ollama: OllamaManager) {
        let store = VocabStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("render-vocab.json"))
        store.removeAll()
        store.record(word: "obstinate", definition: WordDefinition(expression: "obstinate", lemma: "obstinate", partOfSpeech: "형용사", meaning: "고집스러운, 완강한", ipa: "/ˈɑːbstɪnət/", otherMeanings: ["끈질긴", "잘 낫지 않는"]), sentence: "The ephemeral splendour of the evening faded, yet she refused to give up on her obstinate hopes.", sourceTitle: "Pride and Prejudice - RIDI")
        store.record(word: "gave", definition: WordDefinition(expression: "give up", lemma: "give", partOfSpeech: "구동사", meaning: "포기하다", ipa: "/ɡɪv ʌp/", otherMeanings: ["주다"]), sentence: "After three failed attempts, he finally gave up on the idea.", sourceTitle: "Kindle Cloud Reader")
        let views: [(String, AnyView, CGSize)] = [
            ("setup", AnyView(SetupView(ollama: ollama, onDone: {}).background(Color(nsColor: .windowBackgroundColor))), CGSize(width: 560, height: 0)),
            ("settings", AnyView(SettingsView(ollama: ollama)), CGSize(width: 520, height: 0)),
            ("vocabulary", AnyView(VocabularyView(model: VocabularyModel(store: store))), CGSize(width: 900, height: 420)),
        ]
        for (name, view, size) in views {
            let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            let fit = host.fittingSize
            let finalSize = CGSize(width: size.width, height: size.height > 0 ? size.height : fit.height)
            window.setContentSize(finalSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = directory.appendingPathComponent("window-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
    }

    /// Renders the popup in several states and appearances to PNG files.
    @MainActor
    static func renderPopups(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let full = WordDefinition(expression: "give up", lemma: "give", partOfSpeech: "구동사", meaning: "(시도·희망을) 포기하다, 그만두다",
                                  ipa: "/ɡɪv ʌp/", explanation: "여러 번 실패한 뒤 더 이상 하지 않기로 했다는 뜻이다.",
                                  otherMeanings: ["주다", "(파티 등을) 열다", "굴복하다"], source: "ollama:qwen3:8b")
        let cases: [(String, PopupState.Phase, WordDefinition, Bool)] = [
            ("loading", .loading, WordDefinition(), false),
            ("streaming", .streaming, WordDefinition(expression: "give up", lemma: "give", partOfSpeech: "구동사", meaning: "(시도·희망을) 포기하"), false),
            ("done", .done, full, true),
            ("dictionary", .done, WordDefinition(expression: "run", lemma: "run", partOfSpeech: "동사", meaning: "move at a speed faster than a walk",
                                                 ipa: "/rʌn/", explanation: "로컬 AI를 사용할 수 없어 macOS 기본 사전(영영) 뜻을 표시합니다.",
                                                 otherMeanings: ["pass or cause to pass quickly"], source: "dictionary"), false),
            ("error", .error("화면 기록 권한이 필요합니다.\n시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 BookLens를 켜 주세요.", action: .openSetup), WordDefinition(), false),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, phase, def, saved) in cases {
                let state = PopupState()
                state.word = name == "error" ? "" : "gave"
                state.phase = phase
                state.definition = def
                state.saved = saved
                let view = NSHostingView(rootView: PopupView(state: state).padding(20).background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: appearanceName)
                view.frame = CGRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let suffix = appearanceName == .aqua ? "light" : "dark"
                let url = directory.appendingPathComponent("popup-\(name)-\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
    }
}
