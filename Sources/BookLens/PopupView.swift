import AVFoundation
import BookLensCore
import SwiftUI

/// What the popup is currently showing.
final class PopupState: ObservableObject {
    enum Phase: Equatable {
        case loading
        case streaming
        case done
        case error(String, action: ErrorAction?)
    }

    enum ErrorAction: Equatable {
        case openSetup
        case retry
    }

    @Published var word = ""
    @Published var sentence = ""
    @Published var definition = WordDefinition()
    @Published var phase: Phase = .loading
    @Published var saved = false

    var onSave: (() -> Void)?
    var onErrorAction: ((ErrorAction) -> Void)?
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

enum Speech {
    static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45
        synthesizer.speak(utterance)
    }
}

struct PopupView: View {
    @ObservedObject var state: PopupState
    @ObservedObject var settings = AppSettings.shared

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { header }
            switch state.phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("문맥에 맞는 뜻을 찾는 중…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            case .error(let message, let action):
                errorView(message, action: action)
            case .streaming, .done:
                content
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        let d = state.definition
        if !d.expression.isEmpty { return d.expression }
        if !d.lemma.isEmpty { return d.lemma }
        return state.word
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .lineLimit(2)
                .textSelection(.enabled)
            if !state.definition.ipa.isEmpty {
                Text(state.definition.ipa)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Speech.speak(title)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("발음 듣기")
        }
    }

    @ViewBuilder
    private var content: some View {
        let d = state.definition
        if !d.partOfSpeech.isEmpty || (d.lemma.lowercased() != title.lowercased() && !d.lemma.isEmpty) {
            HStack(spacing: 6) {
                if !d.partOfSpeech.isEmpty {
                    Text(d.partOfSpeech)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                if !d.lemma.isEmpty, d.lemma.lowercased() != title.lowercased() {
                    Text("원형 \(d.lemma)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        if d.meaning.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("뜻을 정리하는 중…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        } else {
            Text(d.meaning)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if settings.showExplanation, !d.explanation.isEmpty {
            Text(d.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if settings.showOtherMeanings, !d.otherMeanings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("다른 뜻")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(d.otherMeanings.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        footer
    }

    private var sourceLabel: String {
        let source = state.definition.source
        if source.hasPrefix("ollama:") { return "로컬 AI · " + source.dropFirst("ollama:".count) }
        if source == "dictionary" { return "macOS 기본 사전" }
        if source == "mock" { return "데모 데이터" }
        return source
    }

    private var footer: some View {
        HStack {
            Text(sourceLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if state.phase == .done {
                if state.saved {
                    Label("단어장에 저장됨", systemImage: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        state.onSave?()
                    } label: {
                        Label("단어장에 저장", systemImage: "bookmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.top, 2)
    }

    private func errorView(_ message: String, action: PopupState.ErrorAction?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action == .openSetup ? "설정 도우미 열기" : "다시 시도") {
                    state.onErrorAction?(action)
                }
                .controlSize(.small)
            }
        }
    }
}
