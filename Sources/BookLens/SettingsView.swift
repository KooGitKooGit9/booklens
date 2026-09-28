import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var ollama: OllamaManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("단어 찾기") {
                Picker("호출 방식", selection: $settings.triggerMode) {
                    ForEach(TriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if settings.triggerMode == .dwell {
                    LabeledContent("멈춤 시간") {
                        HStack {
                            Slider(value: $settings.dwellDelay, in: 0.4...2.0, step: 0.1)
                            Text(String(format: "%.1f초", settings.dwellDelay)).monospacedDigit().frame(width: 40)
                        }
                    }
                }
                Toggle("BookLens 켜기", isOn: $settings.enabled)
            }

            Section("팝업") {
                Toggle("뜻 설명 문장 보이기", isOn: $settings.showExplanation)
                Toggle("다른 뜻 보이기", isOn: $settings.showOtherMeanings)
                Toggle("찾은 단어를 단어장에 자동 저장", isOn: $settings.autoSave)
            }

            Section {
                ModelPicker(settings: settings, ollama: ollama)
            } header: {
                Text("로컬 AI 모델 (Ollama)")
            } footer: {
                Text("모든 처리는 이 Mac 안에서만 이루어지며 화면이나 단어가 외부로 전송되지 않습니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("일반") {
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await ollama.refresh() }
    }
}

struct ModelPicker: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var ollama: OllamaManager

    private var allModels: [String] {
        var names = recommendedModels.map(\.name)
        for m in ollama.installedModels where !names.contains(where: { OllamaManager.sameModel($0, m) }) {
            names.append(m)
        }
        return names
    }

    var body: some View {
        switch ollama.status {
        case .unknown:
            ProgressView().controlSize(.small)
        case .notInstalled:
            LabeledContent("상태") {
                HStack {
                    Text("Ollama가 설치되어 있지 않음").foregroundStyle(.secondary)
                    Link("다운로드", destination: URL(string: "https://ollama.com/download")!)
                }
            }
        case .notRunning:
            LabeledContent("상태") {
                HStack {
                    Text("Ollama가 실행 중이 아님").foregroundStyle(.secondary)
                    Button("실행") { Task { await ollama.startServer() } }
                }
            }
        case .running:
            ForEach(allModels, id: \.self) { name in
                modelRow(name)
            }
            if let error = ollama.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ name: String) -> some View {
        let info = recommendedModels.first { $0.name == name }
        let installed = ollama.hasModel(name)
        let selected = OllamaManager.sameModel(settings.model, name)
        HStack {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(info?.title ?? name)
                Text(info.map { "\($0.detail) · \(String(format: "%.1f", $0.sizeGB))GB" } ?? name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = ollama.pullProgress[name] {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%").font(.system(size: 11)).monospacedDigit()
            } else if installed {
                if !selected {
                    Button("사용") {
                        settings.model = name
                        Task { await ollama.warmUp(name) }
                    }
                }
            } else {
                Button("다운로드") { Task { await ollama.pull(name) } }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if installed {
                settings.model = name
                Task { await ollama.warmUp(name) }
            }
        }
    }
}
