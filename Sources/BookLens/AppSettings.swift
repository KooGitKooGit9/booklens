import Foundation
import SwiftUI

enum TriggerMode: String, CaseIterable, Identifiable {
    case optionHover
    case controlHover
    case dwell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionHover: return "⌥ Option 누른 채 단어 위에 올리기"
        case .controlHover: return "⌃ Control 누른 채 단어 위에 올리기"
        case .dwell: return "키 없이 단어 위에서 잠시 멈추기"
        }
    }

    var shortTitle: String {
        switch self {
        case .optionHover: return "⌥ + 마우스"
        case .controlHover: return "⌃ + 마우스"
        case .dwell: return "마우스 멈춤"
        }
    }
}

struct RecommendedModel: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var title: String
    var detail: String
    var sizeGB: Double
}

let recommendedModels: [RecommendedModel] = [
    RecommendedModel(name: "qwen2.5:7b-instruct", title: "Qwen 2.5 7B (추천)", detail: "빠르고 정확함 · Apache 2.0 (상업적 이용 가능)", sizeGB: 4.7),
    RecommendedModel(name: "gemma3:4b", title: "Gemma 3 4B", detail: "가벼움 · 메모리가 적을 때", sizeGB: 3.3),
    RecommendedModel(name: "exaone3.5:7.8b", title: "EXAONE 3.5 7.8B", detail: "한국어 표현이 가장 자연스러움 · 비상업적 이용만 허용", sizeGB: 4.8),
]

let defaultModelName = "qwen2.5:7b-instruct"

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var triggerMode: TriggerMode { didSet { defaults.set(triggerMode.rawValue, forKey: "triggerMode") } }
    @Published var dwellDelay: Double { didSet { defaults.set(dwellDelay, forKey: "dwellDelay") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: "autoSave") } }
    @Published var showExplanation: Bool { didSet { defaults.set(showExplanation, forKey: "showExplanation") } }
    @Published var showOtherMeanings: Bool { didSet { defaults.set(showOtherMeanings, forKey: "showOtherMeanings") } }
    @Published var hasCompletedSetup: Bool { didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "triggerMode": TriggerMode.optionHover.rawValue,
            "dwellDelay": 0.8,
            "model": defaultModelName,
            "autoSave": true,
            "showExplanation": true,
            "showOtherMeanings": true,
            "hasCompletedSetup": false,
        ])
        enabled = defaults.bool(forKey: "enabled")
        triggerMode = TriggerMode(rawValue: defaults.string(forKey: "triggerMode") ?? "") ?? .optionHover
        dwellDelay = defaults.double(forKey: "dwellDelay")
        model = defaults.string(forKey: "model") ?? defaultModelName
        autoSave = defaults.bool(forKey: "autoSave")
        showExplanation = defaults.bool(forKey: "showExplanation")
        showOtherMeanings = defaults.bool(forKey: "showOtherMeanings")
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
    }
}
