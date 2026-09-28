import AppKit
import BookLensCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings.shared
    let ollama = OllamaManager()
    let store = VocabStore()
    private(set) var coordinator: LookupCoordinator!
    private var trigger: TriggerMonitor!
    private var statusItem: NSStatusItem!
    private var vocabularyModel: VocabularyModel!
    private var windows: [String: NSWindow] = [:]
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = LookupCoordinator(settings: settings, ollama: ollama, store: store)
        vocabularyModel = VocabularyModel(store: store)
        coordinator.onOpenSetup = { [weak self] in self?.showSetup() }
        coordinator.onVocabularyChanged = { [weak self] in self?.vocabularyModel.reload() }

        trigger = TriggerMonitor(settings: settings)
        trigger.onTrigger = { [weak self] point in self?.coordinator.lookUp(at: point) }
        trigger.onTick = { [weak self] point, held in self?.coordinator.mouseMoved(to: point, modifierHeld: held) }
        trigger.start()

        setUpStatusItem()
        installDebugHooks()
        settings.$enabled.sink { [weak self] enabled in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
                if !enabled { self?.coordinator.dismiss() }
            }
        }.store(in: &cancellables)

        Task {
            await ollama.refresh()
            if case .notRunning = ollama.status { await ollama.startServer() }
            if !settings.hasCompletedSetup || !ScreenCapturer.hasPermission || !ollama.hasModel(settings.model) {
                showSetup()
            }
            await ollama.warmUp(settings.model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ollama.stopOwnedServer()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showVocabulary() }
        return true
    }

    /// For automated smoke tests only: `defaults write com.booklens.app debugHooks -bool YES`, then post
    /// the distributed notification "com.booklens.debug.lookup" with object "x,y" (Cocoa global points).
    private func installDebugHooks() {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.booklens.debug.lookup"), object: nil, queue: .main) { [weak self] note in
            let parts = (note.object as? String ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            MainActor.assumeIsolated { self?.coordinator.lookUp(at: CGPoint(x: parts[0], y: parts[1]), force: true) }
        }
        // Object "path|px|py": treat the image as if captured at 2x with pixel (px, py) under the cursor.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.booklens.debug.lookupImage"), object: nil, queue: .main) { [weak self] note in
            let parts = (note.object as? String ?? "").split(separator: "|").map(String.init)
            log.error("debug lookupImage: \(parts, privacy: .public)")
            guard parts.count == 3, let px = Double(parts[1]), let py = Double(parts[2]),
                  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: parts[0]) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            let cursor = NSEvent.mouseLocation
            let scale: CGFloat = 2
            let frame = CGRect(x: cursor.x - px / scale, y: cursor.y - (CGFloat(image.height) - py) / scale,
                               width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            MainActor.assumeIsolated {
                self?.coordinator.lookUp(at: cursor, injected: CapturedRegion(image: image, frame: frame, scale: scale))
            }
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = settings.enabled ? "character.book.closed.fill" : "character.book.closed"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "BookLens")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !settings.enabled
        button.toolTip = settings.enabled ? "BookLens — \(settings.triggerMode.shortTitle)로 단어 찾기" : "BookLens (꺼짐)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "BookLens", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for line in statusLines() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "단어 찾기 켜기", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = settings.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(item("단어장 열기…", #selector(openVocabulary), key: "l"))
        menu.addItem(item("설정…", #selector(openSettings), key: ","))
        menu.addItem(item("설정 도우미…", #selector(openSetup), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("BookLens 종료", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func statusLines() -> [String] {
        var lines: [String] = []
        if !ScreenCapturer.hasPermission {
            lines.append("⚠️ 화면 기록 권한이 필요합니다")
        } else if settings.enabled {
            lines.append("\(settings.triggerMode.shortTitle)로 단어 찾기")
        } else {
            lines.append("꺼져 있음")
        }
        switch ollama.status {
        case .running:
            lines.append(ollama.hasModel(settings.model) ? "AI: \(settings.model)" : "⚠️ AI 모델 없음 · 기본 사전 사용")
        case .notRunning, .notInstalled:
            lines.append("⚠️ Ollama 꺼짐 · 기본 사전 사용")
        case .unknown:
            break
        }
        lines.append("단어장: \(store.entries.count)개")
        return lines
    }

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func openVocabulary() { showVocabulary() }
    @objc private func openSettings() { showSettings() }
    @objc private func openSetup() { showSetup() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Windows

    private func present<V: View>(_ key: String, title: String, resizable: Bool, view: () -> V) {
        if let window = windows[key] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: view())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BookLens.\(key)")
        windows[key] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showVocabulary() {
        vocabularyModel.reload()
        present("vocabulary", title: "단어장", resizable: true) {
            VocabularyView(model: vocabularyModel)
        }
        windows["vocabulary"]?.setContentSize(NSSize(width: max(windows["vocabulary"]?.frame.width ?? 0, 880), height: max(windows["vocabulary"]?.frame.height ?? 0, 520)))
    }

    func showSettings() {
        present("settings", title: "BookLens 설정", resizable: false) {
            SettingsView(ollama: ollama)
        }
    }

    func showSetup() {
        present("setup", title: "BookLens 설정 도우미", resizable: false) {
            SetupView(ollama: ollama) { [weak self] in
                self?.windows["setup"]?.close()
                Task { await self?.ollama.warmUp(self?.settings.model ?? defaultModelName) }
            }
        }
    }
}
