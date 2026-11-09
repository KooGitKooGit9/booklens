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

    /// A word's meaning, or the translation of sentences swept with the mouse.
    enum Mode: Equatable {
        case word
        case sentence
    }

    @Published var mode: Mode = .word
    /// Sentence mode: the Korean translation so far.
    @Published var translation = ""
    /// Sentence mode: where the translation came from ("ollama:qwen3:8b").
    @Published var translationSource = ""
    @Published var word = ""
    @Published var sentence = ""
    @Published var definition = WordDefinition()
    @Published var phase: Phase = .loading
    @Published var saved = false

    var onSave: (() -> Void)?
    var onErrorAction: ((ErrorAction) -> Void)?
}

/// Nearly opaque so text stays readable over any page (pure vibrancy turned gray and washed out over white pages).
struct PopupBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            Color(nsColor: .windowBackgroundColor).opacity(0.93)
        }
    }
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
    static let sentenceWidth: CGFloat = 420

    static func width(for mode: PopupState.Mode) -> CGFloat {
        mode == .sentence ? sentenceWidth : width
    }
    /// Main text size, shared by the dictionary senses and the meaning in context.
    static let meaningFont = Font.system(size: 15, weight: .semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .error(let message, let action) = state.phase {
                if state.mode == .word, !title.isEmpty { header }
                errorView(message, action: action)
            } else if state.mode == .sentence {
                SentencePopupContent(state: state)
            } else {
                if !title.isEmpty { header }
                content
            }
        }
        .padding(14)
        .frame(width: Self.width(for: state.mode), alignment: .leading)
        .background(PopupBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
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
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .lineLimit(2)
            if !state.definition.ipa.isEmpty {
                Text(state.definition.ipa)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Speech.speak(title)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("발음 듣기")
        }
    }

    @ViewBuilder
    private var content: some View {
        if settings.showOtherMeanings, hasSenses {
            senses
            Divider()
        }
        context
        footer
    }

    private var hasSenses: Bool {
        let d = state.definition
        return !(d.dictionary?.groups.isEmpty ?? true) || !d.otherMeanings.isEmpty
    }

    /// General senses: from the English–Korean dictionary when the word is in it, else the model's.
    @ViewBuilder
    private var senses: some View {
        let d = state.definition
        VStack(alignment: .leading, spacing: 5) {
            if let entry = d.dictionary, !entry.groups.isEmpty {
                sectionLabel(entry.headword.lowercased() == title.lowercased() ? "사전 뜻" : "사전 뜻 · \(entry.headword)")
                ForEach(entry.groups.prefix(3), id: \.pos) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        posChip(group.pos, highlighted: group.pos == d.partOfSpeech)
                        Text(group.glosses.prefix(3).joined(separator: " · "))
                            .font(Self.meaningFont)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                sectionLabel("일반적인 뜻")
                Text(d.otherMeanings.joined(separator: " · "))
                    .font(Self.meaningFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The meaning in this sentence. While the model is still writing, the section keeps the height of a
    /// typical answer so the popup does not grow line by line.
    private var context: some View {
        let d = state.definition
        let done = state.phase == .done
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                sectionLabel("이 문맥에서")
                if !d.partOfSpeech.isEmpty { posChip(d.partOfSpeech, highlighted: true) }
            }
            .frame(height: 18)
            if !d.meaning.isEmpty {
                Text(d.meaning)
                    .font(Self.meaningFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if done {
                Text("뜻을 찾지 못했어요. 이름·약어이거나 사전에 없는 단어일 수 있어요.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("문맥에 맞는 뜻을 고르는 중…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 19)
            }
            if settings.showExplanation, !d.explanation.isEmpty {
                Text(d.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: done ? 0 : (settings.showExplanation ? 82 : 44), alignment: .topLeading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func posChip(_ pos: String, highlighted: Bool) -> some View {
        Text(pos)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(highlighted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
            .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
            .fixedSize()
    }

    private var sourceLabel: String {
        let d = state.definition
        var parts: [String] = []
        if d.dictionary != nil { parts.append("뉴에이스 영한사전") }
        if d.source.hasPrefix("ollama:") { parts.append("로컬 AI · " + d.source.dropFirst("ollama:".count)) }
        else if d.source == "dictionary", d.dictionary == nil { parts.append("macOS 기본 사전") }
        else if d.source == "mock" { parts.append("데모 데이터") }
        return parts.joined(separator: " + ")
    }

    private var footer: some View {
        HStack {
            Text(sourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
        .frame(height: 16)
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

/// Popup body for sentences swept with the mouse: the original text and its Korean translation.
struct SentencePopupContent: View {
    @ObservedObject var state: PopupState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("문장 번역")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    Speech.speak(state.sentence)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("원문 듣기")
            }
            Text(state.sentence)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Divider()
            if state.translation.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("번역하는 중…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 19)
            } else {
                Text(state.translation)
                    .font(PopupView.meaningFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Text(state.translationSource.hasPrefix("ollama:") ? "로컬 AI · " + state.translationSource.dropFirst("ollama:".count) : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == .done, !state.translation.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.translation, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "복사됨" : "번역 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 16)
            .padding(.top, 2)
        }
        .onChange(of: state.sentence) { _, _ in copied = false }
    }
}
