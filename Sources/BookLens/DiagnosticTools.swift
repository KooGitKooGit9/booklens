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
        let request = LookupRequest(word: hit.word, sentence: hit.sentence, context: hit.context,
                                    dictionary: KoreanDictionary.shared.lookup(hit.word))
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
        let fork = KoreanDictionary.shared.lookup("fork") ?? DictionaryEntry(headword: "fork", ipa: "/fɔːrk/", groups: [
            .init(pos: "명사", glosses: ["농업용 포크, 갈퀴", "포크 모양의 것", "분기"]),
            .init(pos: "동사", glosses: ["포크로 찌르다", "갈래지다, 분기하다", "두 가지 방향으로 발전시키다"]),
        ])
        let forkDone = WordDefinition(expression: "fork", lemma: "fork", partOfSpeech: "동사", meaning: "(프로세스를) 분기하다, 복제해 만들다",
                                      ipa: fork.ipa, explanation: "자식 프로세스를 생성하는 컴퓨터 용어로 쓰인다.", source: "ollama:qwen3:8b", dictionary: fork)
        let use = KoreanDictionary.shared.lookup("use")
        let cases: [(String, PopupState.Phase, WordDefinition, Bool)] = [
            ("loading", .loading, WordDefinition(lemma: fork.headword, ipa: fork.ipa, dictionary: fork), false),
            ("streaming", .streaming, WordDefinition(expression: "fork", lemma: "fork", partOfSpeech: "동사", meaning: "(프로세스를) 분기하",
                                                     ipa: fork.ipa, source: "ollama:qwen3:8b", dictionary: fork), false),
            ("done", .done, forkDone, true),
            ("noun", .done, WordDefinition(expression: "use", lemma: "use", partOfSpeech: "명사", meaning: "(메모리) 사용량", ipa: use?.ipa ?? "",
                                           explanation: "메모리 사용량을 나타내는 기술 용어로 쓰인다.", source: "ollama:qwen3:8b", dictionary: use), true),
            ("unknown", .done, WordDefinition(expression: "soongongdan", lemma: "soongongdan", partOfSpeech: "고유명사",
                                              explanation: "알려진 영어 단어가 아니어서 뜻을 알 수 없습니다.", source: "ollama:qwen3:8b"), false),
            ("no-dictionary", .done, WordDefinition(expression: "give up", lemma: "give", partOfSpeech: "구동사", meaning: "(시도·희망을) 포기하다",
                                                    ipa: "/ɡɪv ʌp/", explanation: "여러 번 실패한 뒤 그만두었다는 뜻이다.",
                                                    otherMeanings: ["포기하다", "굴복하다"], source: "ollama:qwen3:8b"), false),
            ("error", .error("화면 기록 권한이 필요합니다.\n시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 BookLens를 켜 주세요.", action: .openSetup), WordDefinition(), false),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, phase, def, saved) in cases {
                let state = PopupState()
                state.word = name == "error" ? "" : (def.expression.isEmpty ? def.lemma : def.expression)
                state.phase = phase
                state.definition = def
                state.saved = saved
                // White page behind it, as over an e-book.
                let view = NSHostingView(rootView: PopupView(state: state).padding(20).background(Color.white))
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
            let sentence = "The ephemeral glow of the lamp faded, and Mr. Holmes gave up on the investigation entirely."
            for (name, translation, phase) in [("sentence-loading", "", PopupState.Phase.loading),
                                               ("sentence-done", "등불의 덧없는 빛이 사라지자, 홈스 씨는 조사를 완전히 포기했다.", .done)] {
                let state = PopupState()
                state.mode = .sentence
                state.sentence = sentence
                state.translation = translation
                state.translationSource = "ollama:qwen3:8b"
                state.phase = phase
                let view = NSHostingView(rootView: PopupView(state: state).padding(20).background(Color.white))
                view.appearance = NSAppearance(named: appearanceName)
                view.frame = CGRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = directory.appendingPathComponent("popup-\(name)-\(appearanceName == .aqua ? "light" : "dark").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
    }
}
