import AppKit
import BookLensCore
import os

let log = Logger(subsystem: "com.booklens.app", category: "lookup")

/// Runs the capture → OCR → locate → define pipeline and drives the overlay.
@MainActor
final class LookupCoordinator {
    let settings: AppSettings
    let ollama: OllamaManager
    let store: VocabStore
    let overlay = OverlayController()
    let capturer = ScreenCapturer()
    private let reader = WordReader()
    private let cache = LookupCache()
    private var task: Task<Void, Never>?
    private var shownRequest: LookupRequest?
    private var awaySince: Date?

    var onOpenSetup: (() -> Void)?
    var onVocabularyChanged: (() -> Void)?
    /// Called when a lookup must be retriggered at the same point (retry button).
    private var lastPoint: CGPoint?
    /// The last sentence sweep, retried instead of `lastPoint` when set.
    private var lastSweep: [CGPoint]?
    /// Recent translations, keyed by source text.
    private var translations: [String: String] = [:]

    init(settings: AppSettings, ollama: OllamaManager, store: VocabStore) {
        self.settings = settings
        self.ollama = ollama
        self.store = store
        overlay.state.onErrorAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .openSetup:
                self.overlay.hide()
                self.onOpenSetup?()
            case .retry:
                if let path = self.lastSweep {
                    self.translateSentence(along: path)
                } else if let p = self.lastPoint {
                    self.lookUp(at: p, force: true)
                }
            }
        }
        overlay.state.onSave = { [weak self] in self?.saveCurrent() }
    }

    /// Hides the popup once the mouse has left the word and popup for a moment.
    func mouseMoved(to point: CGPoint, modifierHeld: Bool) {
        guard overlay.isVisible else { awaySince = nil; return }
        // While the trigger key is held the next lookup replaces the popup, so don't flicker it closed.
        if modifierHeld || overlay.isNear(point) {
            awaySince = nil
            return
        }
        let now = Date()
        if awaySince == nil { awaySince = now }
        if now.timeIntervalSince(awaySince!) > 0.3 {
            dismiss()
        }
    }

    func dismiss() {
        task?.cancel()
        overlay.hide()
        shownRequest = nil
        awaySince = nil
    }

    /// Whether `point` is on the shown word or its popup; nil when no word popup is shown.
    func isOnCurrentLookup(_ point: CGPoint) -> Bool? {
        guard overlay.isVisible, overlay.state.mode == .word else { return nil }
        return overlay.currentWordRect.insetBy(dx: -4, dy: -4).contains(point) || overlay.popupFrame.contains(point)
    }

    /// Debug only: runs the pipeline on a supplied image instead of a screen capture.
    func lookUp(at point: CGPoint, injected region: CapturedRegion) {
        lastPoint = point
        lastSweep = nil
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(at: point, injected: region)
        }
    }

    func lookUp(at point: CGPoint, force: Bool = false) {
        if overlay.isVisible, overlay.popupFrame.contains(point) { return }
        if !force, overlay.isVisible, overlay.state.mode == .word,
           overlay.currentWordRect.insetBy(dx: -1, dy: -1).contains(point) { return }
        lastPoint = point
        lastSweep = nil
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(at: point)
        }
    }

    private func run(at point: CGPoint, injected: CapturedRegion? = nil) async {
        let started = Date()
        let region: CapturedRegion
        do {
            if let injected {
                region = injected
            } else {
                region = try await capturer.capture(around: point)
            }
        } catch let error as CaptureError {
            if Task.isCancelled { return }
            showError(error.localizedDescription + (error == .permissionDenied ? "\n시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 BookLens를 켜 주세요." : ""),
                      action: error == .permissionDenied ? .openSetup : .retry,
                      near: point)
            return
        } catch {
            showError(error.localizedDescription, action: .retry, near: point)
            return
        }
        if Task.isCancelled { return }
        let captured = Date()
        if let dumpPath = UserDefaults.standard.string(forKey: "debugCaptureDump") {
            // Smoke tests only: `defaults write com.booklens.app debugCaptureDump /path/capture.png`.
            let url = URL(fileURLWithPath: dumpPath) as CFURL
            if let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, region.image, nil)
                CGImageDestinationFinalize(dest)
            }
            log.info("Captured \(Int(region.frame.minX)),\(Int(region.frame.minY)) \(Int(region.frame.width))x\(Int(region.frame.height)) at \(Int(point.x)),\(Int(point.y))")
        }

        let reader = self.reader
        let image = region.image
        let imagePoint = region.imagePoint(for: point)
        let found: WordHit?
        do {
            found = try await Task.detached(priority: .userInitiated) { try reader.read(image, at: imagePoint) }.value
        } catch {
            log.error("OCR failed: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }

        guard let hit = found else {
            log.debug("No word at point")
            if overlay.isVisible, !overlay.isNear(point) { dismiss() }
            return
        }
        let recognized = Date()
        log.info("Word '\(hit.word, privacy: .public)' capture \(Int(captured.timeIntervalSince(started) * 1000))ms, OCR \(Int(recognized.timeIntervalSince(captured) * 1000))ms")

        let word = hit.word
        let dictionary = await Task.detached(priority: .userInitiated) { KoreanDictionary.shared.lookup(word) }.value
        if Task.isCancelled { return }
        let request = LookupRequest(word: hit.word, sentence: hit.sentence, context: hit.context, dictionary: dictionary)
        let wordRect = region.globalRect(for: hit.rect)
        if overlay.isVisible, shownRequest == request { return }
        shownRequest = request

        let state = overlay.state
        state.mode = .word
        state.word = hit.word
        state.sentence = hit.sentence
        // The dictionary senses show right away; the model fills in the meaning in context.
        state.definition = WordDefinition(lemma: dictionary?.headword ?? "", ipa: dictionary?.ipa ?? "", dictionary: dictionary)
        state.saved = false
        state.phase = .loading
        overlay.show(at: wordRect)
        awaySince = nil

        let title = ScreenCapturer.windowTitle(at: point)

        if let cached = cache.get(request) {
            state.definition = cached
            state.phase = .done
            finish(request: request, definition: cached, title: title)
            return
        }

        let provider = await makeProvider()
        do {
            for try await event in provider.lookup(request) {
                if Task.isCancelled { return }
                switch event {
                case .partial(let d):
                    state.definition = d
                    state.phase = .streaming
                case .complete(let d):
                    state.definition = d
                    state.phase = .done
                    if d.source != "dictionary" { cache.set(request, d) }
                    finish(request: request, definition: d, title: title)
                }
            }
            log.info("Lookup done in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        } catch {
            if Task.isCancelled { return }
            state.phase = .error("뜻을 가져오지 못했습니다. \(error.localizedDescription)", action: .retry)
        }
    }

    private var pendingSave: (request: LookupRequest, definition: WordDefinition, title: String)?

    private func finish(request: LookupRequest, definition: WordDefinition, title: String) {
        pendingSave = (request, definition, title)
        let key = (definition.expression.isEmpty ? definition.lemma : definition.expression).lowercased()
        // Words without a meaning (names, OCR errors) are not worth saving automatically.
        if settings.autoSave, !definition.meaning.isEmpty {
            saveCurrent()
        } else {
            overlay.state.saved = !key.isEmpty && store.contains(expression: key)
        }
    }

    private func saveCurrent() {
        guard let pending = pendingSave else { return }
        store.record(word: pending.request.word, definition: pending.definition, sentence: pending.request.sentence, sourceTitle: pending.title)
        overlay.state.saved = true
        onVocabularyChanged?()
    }

    private func makeProvider() async -> MeaningProvider {
        if !ollama.isRunning { await ollama.refresh() }
        let model = settings.model
        if ollama.isRunning, ollama.hasModel(model) {
            return FallbackMeaningProvider(primary: OllamaMeaningProvider(client: ollama.client, model: model),
                                           fallback: SystemDictionaryProvider())
        }
        if case .notRunning = ollama.status {
            Task { await ollama.startServer() }
        }
        return SystemDictionaryProvider()
    }

    // MARK: - Sentence translation

    /// Translates the sentences under a mouse sweep (trigger key held while moving across text).
    func translateSentence(along path: [CGPoint]) {
        guard !path.isEmpty else { return }
        lastSweep = path
        task?.cancel()
        task = Task { [weak self] in
            await self?.runSentence(along: path)
        }
    }

    private func runSentence(along path: [CGPoint]) async {
        let started = Date()
        let ys = path.map(\.y)
        let top = ys.max()!, bottom = ys.min()!
        let center = CGPoint(x: path[0].x, y: (top + bottom) / 2)
        // Room above and below the swept lines for the rest of the sentences.
        let halfHeight = max(capturer.halfHeight, (top - bottom) / 2 + 160)
        let region: CapturedRegion
        do {
            region = try await capturer.capture(around: center, halfHeight: halfHeight)
        } catch let error as CaptureError {
            if Task.isCancelled { return }
            showError(error.localizedDescription, action: error == .permissionDenied ? .openSetup : .retry, near: path.last!)
            return
        } catch {
            showError(error.localizedDescription, action: .retry, near: path.last!)
            return
        }
        if Task.isCancelled { return }

        let recognizer = reader.recognizer
        let image = region.image
        let points = path.map { region.imagePoint(for: $0) }
        let found: SentenceHit?
        do {
            found = try await Task.detached(priority: .userInitiated) {
                let lines = try recognizer.recognize(image)
                return WordLocator.locateSentence(along: points, in: lines, imageSize: CGSize(width: image.width, height: image.height))
            }.value
        } catch {
            log.error("OCR failed: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }
        guard let hit = found else {
            log.debug("No text under sweep")
            return
        }
        log.info("Sweep: \(hit.text.count) chars, capture + OCR \(Int(Date().timeIntervalSince(started) * 1000))ms")

        let lineRects = hit.lineRects.map { region.globalRect(for: $0) }
        let anchor = lineRects.dropFirst().reduce(lineRects.first ?? CGRect(origin: path.last!, size: .zero)) { $0.union($1) }
        let state = overlay.state
        state.mode = .sentence
        state.word = ""
        state.sentence = hit.text
        state.translation = ""
        state.translationSource = ""
        state.phase = .loading
        shownRequest = nil
        overlay.show(at: anchor, lines: lineRects)
        awaySince = nil

        if let cached = translations[hit.text] {
            state.translation = cached
            state.translationSource = "ollama:\(settings.model)"
            state.phase = .done
            return
        }
        if !ollama.isRunning { await ollama.refresh() }
        let model = settings.model
        guard ollama.isRunning, ollama.hasModel(model) else {
            if case .notRunning = ollama.status { Task { await ollama.startServer() } }
            state.phase = .error("문장 번역에는 로컬 AI(Ollama)와 모델이 필요합니다.", action: .openSetup)
            return
        }
        state.translationSource = "ollama:\(model)"
        do {
            for try await text in OllamaSentenceTranslator(client: ollama.client, model: model).translate(hit.text) {
                if Task.isCancelled { return }
                state.translation = text
                state.phase = .streaming
            }
            if Task.isCancelled { return }
            state.phase = .done
            if !state.translation.isEmpty {
                if translations.count > 50 { translations.removeAll() }
                translations[hit.text] = state.translation
            }
            log.info("Translation done in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        } catch {
            if Task.isCancelled { return }
            state.phase = .error("번역하지 못했습니다. \(error.localizedDescription)", action: .retry)
        }
    }

    private func showError(_ message: String, action: PopupState.ErrorAction?, near point: CGPoint) {
        let state = overlay.state
        state.mode = .word
        state.word = ""
        state.definition = WordDefinition()
        state.phase = .error(message, action: action)
        shownRequest = nil
        overlay.show(at: CGRect(x: point.x, y: point.y - 8, width: 1, height: 16))
    }
}
