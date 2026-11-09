import AppKit
import BookLensCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VocabularyModel: ObservableObject {
    let store: VocabStore
    @Published private(set) var entries: [VocabEntry] = []

    init(store: VocabStore) {
        self.store = store
        reload()
    }

    func reload() {
        entries = store.entries
    }

    func delete(_ ids: Set<UUID>) {
        store.remove(ids: ids)
        reload()
    }

    func exportCSV(_ selection: [VocabEntry]?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "BookLens 단어장 \(formatter.string(from: Date())).csv"
        panel.message = "Anki 등 단어 암기 앱으로 가져올 수 있는 CSV 파일로 저장합니다."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // UTF-8 BOM so Excel and Numbers show Korean correctly.
            let data = Data([0xEF, 0xBB, 0xBF]) + Data(store.csv(for: selection).utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var model: VocabularyModel
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\VocabEntry.updatedAt, order: .reverse)]

    private var filtered: [VocabEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? model.entries : model.entries.filter {
            $0.key.contains(q) || $0.word.lowercased().contains(q) || $0.definition.meaning.lowercased().contains(q)
                || $0.sentence.lowercased().contains(q) || $0.sourceTitle.lowercased().contains(q)
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                emptyState
            } else {
                Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("단어", value: \.key) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.definition.expression.isEmpty ? e.word : e.definition.expression)
                                .font(.system(size: 13, weight: .semibold, design: .serif))
                            if !e.definition.ipa.isEmpty {
                                Text(e.definition.ipa).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn("뜻") { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text([e.definition.partOfSpeech, e.definition.meaning].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12))
                            if !e.definition.generalSenses.isEmpty {
                                Text(e.definition.generalSenses.joined(separator: " / "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn("문장") { e in
                        Text(e.sentence).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(e.sentence)
                    }
                    .width(min: 160, ideal: 320)
                    TableColumn("출처", value: \.sourceTitle) { e in
                        Text(e.sourceTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(e.sourceTitle)
                    }
                    .width(min: 60, ideal: 120)
                    TableColumn("횟수", value: \.lookupCount) { e in
                        Text("\(e.lookupCount)").font(.system(size: 11)).monospacedDigit()
                    }
                    .width(40)
                    TableColumn("최근", value: \.updatedAt) { e in
                        Text(e.updatedAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("발음 듣기") {
                        if let e = model.entries.first(where: { ids.contains($0.id) }) {
                            Speech.speak(e.definition.expression.isEmpty ? e.word : e.definition.expression)
                        }
                    }
                    Button("선택 항목 CSV로 내보내기…") { model.exportCSV(model.entries.filter { ids.contains($0.id) }) }
                    Divider()
                    Button("삭제", role: .destructive) { model.delete(ids) }
                }
                .onDeleteCommand { model.delete(selection) }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "단어, 뜻, 문장 검색")
        .toolbar {
            ToolbarItemGroup {
                Text("\(model.entries.count)개 단어").foregroundStyle(.secondary).font(.system(size: 12))
                Button {
                    model.delete(selection)
                } label: {
                    Label("삭제", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help("선택한 단어 삭제 (⌫)")
                Button {
                    model.exportCSV(nil)
                } label: {
                    Label("CSV 내보내기", systemImage: "square.and.arrow.up")
                }
                .disabled(model.entries.isEmpty)
                .help("전체 단어장을 Anki용 CSV로 내보내기")
            }
        }
        .frame(minWidth: 720, minHeight: 400)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("아직 저장된 단어가 없어요")
                .font(.headline)
            Text("전자책을 읽다가 \(AppSettings.shared.triggerMode.shortTitle)로 단어를 찾으면 여기에 자동으로 모입니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
