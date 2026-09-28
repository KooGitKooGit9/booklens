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
    private let recognizer = TextRecognizer()
    private let cache = LookupCache()
    private var task: Task<Void, Never>?
    private var shownRequest: LookupRequest?
    private var awaySince: Date?

    var onOpenSetup: (() -> Void)?
    var onVocabularyChanged: (() -> Void)?
    /// Called when a lookup must be retriggered at the same point (retry button).
    private var lastPoint: CGPoint?

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
                if let p = self.lastPoint { self.lookUp(at: p, force: true) }
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

    /// Debug only: runs the pipeline on a supplied image instead of a screen capture.
    func lookUp(at point: CGPoint, injected region: CapturedRegion) {
        lastPoint = point
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(at: point, injected: region)
        }
    }

    func lookUp(at point: CGPoint, force: Bool = false) {
        if overlay.isVisible, overlay.popupFrame.contains(point) { return }
        if !force, overlay.isVisible, overlay.currentWordRect.insetBy(dx: -1, dy: -1).contains(point) { return }
        lastPoint = point
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

        let recognizer = self.recognizer
        let image = region.image
        let lines: [RecognizedLine]
        do {
            lines = try await Task.detached(priority: .userInitiated) { try recognizer.recognize(image) }.value
        } catch {
            log.error("OCR failed: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }

        guard let hit = WordLocator.locate(point: region.imagePoint(for: point), in: lines, imageSize: CGSize(width: image.width, height: image.height)) else {
            log.error("No word at point (\(lines.count) lines)")
            if overlay.isVisible, !overlay.isNear(point) { dismiss() }
            return
        }
        let recognized = Date()
        log.error("Word '\(hit.word, privacy: .public)' capture \(Int(captured.timeIntervalSince(started) * 1000))ms, OCR \(Int(recognized.timeIntervalSince(captured) * 1000))ms")

        let request = LookupRequest(word: hit.word, sentence: hit.sentence, context: hit.context)
        let wordRect = region.globalRect(for: hit.rect)
        if overlay.isVisible, shownRequest == request { return }
        shownRequest = request

        let state = overlay.state
        state.word = hit.word
        state.sentence = hit.sentence
        state.definition = WordDefinition()
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
        if settings.autoSave, definition.source != "dictionary" || !definition.meaning.isEmpty {
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

    private func showError(_ message: String, action: PopupState.ErrorAction?, near point: CGPoint) {
        let state = overlay.state
        state.word = ""
        state.definition = WordDefinition()
        state.phase = .error(message, action: action)
        shownRequest = nil
        overlay.show(at: CGRect(x: point.x, y: point.y - 8, width: 1, height: 16))
    }
}
