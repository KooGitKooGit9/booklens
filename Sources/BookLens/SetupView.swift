import AppKit
import SwiftUI

/// First-run checklist: screen recording permission, Ollama, and a model.
struct SetupView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var ollama: OllamaManager
    var onDone: () -> Void

    @State private var hasScreenPermission = ScreenCapturer.hasPermission
    @State private var requestedPermission = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var modelReady: Bool { ollama.isRunning && ollama.hasModel(settings.model) }
    private var ready: Bool { hasScreenPermission && modelReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BookLens 시작하기").font(.system(size: 20, weight: .bold))
                    Text("복사가 안 되는 전자책에서도 단어 위에 마우스만 올리면 문맥에 맞는 뜻을 보여줍니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                step(number: 1, title: "화면 기록 권한", done: hasScreenPermission,
                     detail: hasScreenPermission ? "허용됨" : "화면의 글자를 읽기 위해 필요합니다. 화면은 이 Mac 안에서만 처리되고 저장되지 않습니다.") {
                    if !hasScreenPermission {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button(requestedPermission ? "시스템 설정 열기" : "권한 허용") {
                                if requestedPermission {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                } else {
                                    requestedPermission = true
                                    ScreenCapturer.requestPermission()
                                }
                            }
                            if requestedPermission {
                                Button("허용 후 다시 시작") { AppRelauncher.relaunch() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Divider().padding(.leading, 44)
                step(number: 2, title: "로컬 AI (Ollama)", done: ollama.isRunning, detail: ollamaDetail) {
                    switch ollama.status {
                    case .notInstalled:
                        Link("다운로드", destination: URL(string: "https://ollama.com/download")!)
                    case .notRunning:
                        Button("실행") { Task { await ollama.startServer() } }
                    default:
                        EmptyView()
                    }
                }
                Divider().padding(.leading, 44)
                step(number: 3, title: "AI 모델", done: modelReady, detail: modelDetail) {
                    if ollama.isRunning, !ollama.hasModel(settings.model) {
                        if let p = ollama.pullProgress[settings.model] {
                            HStack {
                                ProgressView(value: p).frame(width: 90)
                                Text("\(Int(p * 100))%").monospacedDigit().font(.system(size: 11))
                            }
                        } else {
                            Button("다운로드") { Task { await ollama.pull(settings.model) } }
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 6) {
                Text("사용법").font(.system(size: 13, weight: .semibold))
                Label("전자책(웹 뷰어, 리디, 킨들 등)을 열고 모르는 단어 위에 마우스를 올린 채 **⌥ Option** 키를 누르세요.", systemImage: "cursorarrow.rays")
                Label("팝업에서 🔊로 발음을 듣고, 찾은 단어는 메뉴 막대의 단어장에 자동 저장됩니다.", systemImage: "bookmark")
                Label("마우스를 단어에서 멀리 움직이거나 클릭하면 팝업이 닫힙니다.", systemImage: "xmark.circle")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            if let error = ollama.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                if !ready {
                    Text(modelReady ? "" : "AI 모델이 준비되기 전에는 macOS 기본 사전(영영)으로 뜻을 보여줍니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(ready ? "시작하기" : "나중에") {
                    settings.hasCompletedSetup = true
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await ollama.refresh() }
        .onReceive(timer) { _ in
            hasScreenPermission = ScreenCapturer.hasPermission
            Task { await ollama.refresh() }
        }
    }

    private var ollamaDetail: String {
        switch ollama.status {
        case .unknown: return "확인 중…"
        case .notInstalled: return "ollama.com에서 무료로 설치할 수 있습니다. (또는 터미널에서 brew install ollama)"
        case .notRunning: return "설치되어 있지만 실행 중이 아닙니다."
        case .running(let v): return "실행 중 (v\(v))"
        }
    }

    private var modelDetail: String {
        let info = recommendedModels.first { $0.name == settings.model }
        if modelReady { return "\(info?.title ?? settings.model) 준비됨" }
        if let status = ollama.pullStatus[settings.model] { return "다운로드 중 · \(status)" }
        return "\(info?.title ?? settings.model) · 약 \(String(format: "%.1f", info?.sizeGB ?? 5))GB를 한 번만 다운로드합니다."
    }

    private func step<Accessory: View>(number: Int, title: String, done: Bool, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
