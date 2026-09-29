import Foundation

public enum Prompt {
    public static let system = """
    You are a precise English→Korean dictionary for Korean readers of English books.
    Given a WORD and the SENTENCE it appears in, explain what the word means in THIS sentence.
    Reply with JSON only. Write "meaning", "explanation" and "other_meanings" in natural Korean (Hangul). Never use Chinese characters.

    Fields:
    - expression: if the word is part of a phrasal verb, idiom or hyphenated compound in this sentence (e.g. "gave up", "looked forward to", "on the other hand"), that phrase in dictionary form ("give up"); otherwise the word's dictionary form.
    - lemma: dictionary form of the single WORD ("ran" → "run", "mice" → "mouse", "bore" as past tense → "bear").
    - pos: Korean part of speech of the expression AS USED IN THIS SENTENCE (e.g. "pay a fine" → 명사): 명사, 동사, 형용사, 부사, 전치사, 접속사, 대명사, 감탄사, 구동사, 관용구, 고유명사.
    - meaning: a short Korean dictionary gloss (2–12 words) of the expression as used here. Not a translation of the whole sentence.
    - ipa: IPA pronunciation of the expression (American), with slashes.
    - explanation: one short Korean sentence (under 40 characters) on why this sense fits the context.
    - other_meanings: up to 3 other common senses of the lemma as short Korean glosses, each different from "meaning" and from each other. Empty if none.
    """

    public static let exampleUser = """
    WORD: bank
    SENTENCE: They had a picnic on the grassy bank of the river.
    """

    public static let exampleAssistant = """
    {"expression":"bank","meaning":"(강·호수의) 둑, 기슭","lemma":"bank","pos":"명사","ipa":"/bæŋk/","explanation":"강(river)과 함께 쓰여 물가의 비탈진 땅을 가리킨다.","other_meanings":["은행","저장소","(비행기의) 경사 선회"]}
    """

    public static let example2User = """
    WORD: looked
    SENTENCE: She looked after her younger brother all summer.
    """

    public static let example2Assistant = """
    {"expression":"look after","meaning":"~을 돌보다, 보살피다","lemma":"look","pos":"구동사","ipa":"/lʊk ˈæftər/","explanation":"after와 함께 쓰여 누군가를 돌본다는 뜻이다.","other_meanings":["보다","~처럼 보이다","향하다"]}
    """

    public static func user(for request: LookupRequest) -> String {
        var text = "WORD: \(request.word)\nSENTENCE: \(request.sentence)"
        let context = request.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty, context != request.sentence {
            text += "\nSURROUNDING TEXT (for reference): \(context)"
        }
        return text
    }

    /// JSON schema passed to Ollama's structured output, as raw JSON: Ollama generates the fields in the
    /// order written here, and a Swift dictionary would serialize them in a random order on each launch.
    /// "meaning" streams right after "expression" (~0.5 s sooner than after lemma/pos). Putting "meaning"
    /// first is faster still but loses context: without naming the expression first the model falls back
    /// to the common sense.
    public static let fieldOrder = ["expression", "meaning", "lemma", "pos", "ipa", "explanation", "other_meanings"]

    public static let schema: String = {
        let properties = fieldOrder.map { name in
            name == "other_meanings"
                ? #""other_meanings":{"type":"array","items":{"type":"string"},"maxItems":3}"#
                : #""\#(name)":{"type":"string"}"#
        }
        let required = fieldOrder.map { "\"\($0)\"" }
        return #"{"type":"object","properties":{"# + properties.joined(separator: ",") + #"},"required":["# + required.joined(separator: ",") + "]}"
    }()
}
