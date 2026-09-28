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
    {"expression":"bank","lemma":"bank","pos":"명사","meaning":"(강·호수의) 둑, 기슭","ipa":"/bæŋk/","explanation":"강(river)과 함께 쓰여 물가의 비탈진 땅을 가리킨다.","other_meanings":["은행","저장소","(비행기의) 경사 선회"]}
    """

    public static let example2User = """
    WORD: looked
    SENTENCE: She looked after her younger brother all summer.
    """

    public static let example2Assistant = """
    {"expression":"look after","lemma":"look","pos":"구동사","meaning":"~을 돌보다, 보살피다","ipa":"/lʊk ˈæftər/","explanation":"after와 함께 쓰여 누군가를 돌본다는 뜻이다.","other_meanings":["보다","~처럼 보이다","향하다"]}
    """

    public static func user(for request: LookupRequest) -> String {
        var text = "WORD: \(request.word)\nSENTENCE: \(request.sentence)"
        let context = request.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty, context != request.sentence {
            text += "\nSURROUNDING TEXT (for reference): \(context)"
        }
        return text
    }

    /// JSON schema passed to Ollama's structured output. Field order matters: "meaning" streams early.
    public static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "expression": ["type": "string"],
            "lemma": ["type": "string"],
            "pos": ["type": "string"],
            "meaning": ["type": "string"],
            "ipa": ["type": "string"],
            "explanation": ["type": "string"],
            "other_meanings": ["type": "array", "items": ["type": "string"], "maxItems": 3],
        ],
        "required": ["expression", "lemma", "pos", "meaning", "ipa", "explanation", "other_meanings"],
    ]
}
