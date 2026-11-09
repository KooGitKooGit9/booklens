import Foundation

public enum Prompt {
    /// System prompt. With `dictionary`, the request carries dictionary senses and the model only picks and
    /// words the sense in context; without it the model also lists general senses, the lemma and the IPA.
    /// (One shared prompt for both was tried so Ollama could reuse the cached prefix, but it was slower on
    /// dictionary words — the common case — and lost phrase detection, e.g. "on the other hand" → "hand".)
    public static func system(dictionary: Bool) -> String {
        var lines = [
            "You are a precise English→Korean dictionary for Korean readers of English books.",
            "Given a WORD and the SENTENCE it appears in, explain what the word means in THIS sentence.",
            "Reply with JSON only. Write the Korean fields in natural Korean (Hangul). Never use Chinese characters.",
        ]
        if dictionary {
            lines.append("""
            A DICTIONARY line lists the word's senses from an English–Korean dictionary, grouped by part of speech. \
            Base "meaning" on the sense that fits the sentence; adapt its wording to the context (e.g. a computing sense \
            in a technical text), but never invent a sense unrelated to the word.
            """)
        }
        lines.append("""
        For a proper noun, give what it refers to if known (e.g. "런던(영국의 수도)"). If the word is not a known English \
        word (a username, code or OCR error), set "meaning" to "" and say so briefly in "explanation".
        """)
        lines.append("")
        lines.append("Fields:")
        lines.append(#"- expression: if the word is part of a phrasal verb, idiom or hyphenated compound in this sentence (e.g. "gave up", "looked forward to", "on the other hand"), that phrase in dictionary form ("give up"); otherwise the word's dictionary form."#)
        lines.append(#"- pos: Korean part of speech of the expression AS USED IN THIS SENTENCE (e.g. "pay a fine" → 명사, "small memory use" → 명사): 명사, 동사, 형용사, 부사, 전치사, 접속사, 대명사, 감탄사, 구동사, 관용구, 고유명사."#)
        if !dictionary {
            lines.append("- other_meanings: up to 3 common dictionary senses of the expression for that part of speech, as short Korean glosses, most common first. Empty if none.")
        }
        lines.append("- meaning: a short Korean dictionary gloss (2–12 words) of the ONE sense used here. Not a list of senses, not a translation of the whole sentence.")
        if !dictionary {
            lines.append(#"- lemma: dictionary form of the single WORD ("ran" → "run", "mice" → "mouse", "bore" as past tense → "bear")."#)
            lines.append("- ipa: IPA pronunciation of the expression (American), with slashes.")
        }
        lines.append("- explanation: one short Korean sentence (under 40 characters) on why this sense fits the context.")
        return lines.joined(separator: "\n")
    }

    static let example = LookupRequest(
        word: "bank",
        sentence: "They had a picnic on the grassy bank of the river.",
        dictionary: DictionaryEntry(headword: "bank", ipa: "/bæŋk/", groups: [
            .init(pos: "명사", glosses: ["은행", "둑, 제방", "저장소"]),
            .init(pos: "동사", glosses: ["은행에 맡기다", "둑을 쌓다"]),
        ]))

    static let exampleFields: [String: String] = [
        "expression": #""bank""#,
        "pos": #""명사""#,
        "other_meanings": #"["은행","(강·호수의) 둑","저장소"]"#,
        "meaning": #""(강·호수의) 둑, 기슭""#,
        "lemma": #""bank""#,
        "ipa": #""/bæŋk/""#,
        "explanation": #""강(river)과 함께 쓰여 물가의 비탈진 땅을 가리킨다.""#,
    ]

    public static func exampleAssistant(dictionary: Bool) -> String {
        "{" + fieldOrder(dictionary: dictionary).map { "\"\($0)\":\(exampleFields[$0]!)" }.joined(separator: ",") + "}"
    }

    public static func user(for request: LookupRequest) -> String {
        var text = "WORD: \(request.word)\nSENTENCE: \(request.sentence)"
        let context = request.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty, context != request.sentence {
            text += "\nSURROUNDING TEXT (for reference): \(context)"
        }
        if let dictionary = request.dictionary {
            text += "\nDICTIONARY: \(dictionary.promptText)"
        }
        return text
    }

    public static func messages(for request: LookupRequest) -> [OllamaClient.ChatMessage] {
        let dictionary = request.dictionary != nil
        var example = example
        if !dictionary { example.dictionary = nil }
        return [
            .init(role: "system", content: system(dictionary: dictionary)),
            .init(role: "user", content: user(for: example)),
            .init(role: "assistant", content: exampleAssistant(dictionary: dictionary)),
            .init(role: "user", content: user(for: request)),
        ]
    }

    /// Order in which Ollama generates the fields (it follows the schema's property order). "expression"
    /// comes first: without naming the expression first the model falls back to the common sense. "pos" is
    /// next so the popup's part-of-speech label is settled early and the senses agree with it.
    public static func fieldOrder(dictionary: Bool) -> [String] {
        dictionary
            ? ["expression", "pos", "meaning", "explanation"] // lemma and IPA come from the dictionary
            : ["expression", "pos", "other_meanings", "meaning", "lemma", "ipa", "explanation"]
    }

    /// Length caps keep a derailed small model from streaming garbage until `num_predict` runs out.
    static let maxLength = ["expression": 40, "pos": 8, "meaning": 40, "lemma": 30, "ipa": 40, "explanation": 70]

    /// JSON schema passed to Ollama's structured output, as raw JSON: a Swift dictionary would serialize
    /// the properties in a random order on each launch.
    public static func schema(dictionary: Bool) -> String {
        let order = fieldOrder(dictionary: dictionary)
        let properties = order.map { name in
            name == "other_meanings"
                ? #""other_meanings":{"type":"array","items":{"type":"string","maxLength":24},"maxItems":3}"#
                : #""\#(name)":{"type":"string","maxLength":\#(maxLength[name] ?? 60)}"#
        }
        let required = order.map { "\"\($0)\"" }
        return #"{"type":"object","properties":{"# + properties.joined(separator: ",") + #"},"required":["# + required.joined(separator: ",") + "]}"
    }
}

/// Prompt for translating the sentences swept with the mouse.
public enum TranslationPrompt {
    public static let system = """
    You translate English text from books into natural Korean for Korean readers.
    Translate the TEXT faithfully and completely, keeping its tone. Write fluent Korean (Hangul); never use Chinese characters.
    Keep names in their usual Korean spelling. Reply with the Korean translation only: no notes, no quotes, no romanization.
    """

    static let exampleText = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."
    static let exampleTranslation = "재산깨나 있는 독신 남자에게 아내가 꼭 필요하다는 것은 누구나 인정하는 진리이다."

    public static func messages(for text: String) -> [OllamaClient.ChatMessage] {
        [
            .init(role: "system", content: system),
            .init(role: "user", content: "TEXT: \(exampleText)"),
            .init(role: "assistant", content: exampleTranslation),
            .init(role: "user", content: "TEXT: \(text)"),
        ]
    }

    /// Trims what small models sometimes wrap around the answer.
    public static func clean(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["번역:", "번역 :", "Translation:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if text.count >= 2, let f = text.first, let l = text.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
