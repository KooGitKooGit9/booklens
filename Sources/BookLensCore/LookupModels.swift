import Foundation

/// What the popup shows for one lookup. Fields fill in progressively while the model streams.
public struct WordDefinition: Codable, Equatable, Sendable {
    /// The word or multi-word expression the looked-up word belongs to (e.g. "give up").
    public var expression: String
    /// Dictionary form of the word ("ran" → "run").
    public var lemma: String
    /// Part of speech in Korean ("동사").
    public var partOfSpeech: String
    /// Meaning in this sentence, in Korean.
    public var meaning: String
    public var ipa: String
    /// One-sentence explanation of why this sense applies here.
    public var explanation: String
    /// Other common meanings, in Korean.
    public var otherMeanings: [String]
    /// Where the definition came from ("ollama:qwen2.5:7b-instruct", "dictionary", "mock").
    public var source: String
    /// Senses from the English–Korean dictionary, shown above the meaning in context.
    public var dictionary: DictionaryEntry?

    public init(expression: String = "", lemma: String = "", partOfSpeech: String = "", meaning: String = "",
                ipa: String = "", explanation: String = "", otherMeanings: [String] = [], source: String = "",
                dictionary: DictionaryEntry? = nil) {
        self.expression = expression
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.meaning = meaning
        self.ipa = ipa
        self.explanation = explanation
        self.otherMeanings = otherMeanings
        self.source = source
        self.dictionary = dictionary
    }

    public var isEmpty: Bool { meaning.isEmpty && lemma.isEmpty && expression.isEmpty }

    /// General senses for lists and exports: the dictionary's, else the model's other meanings.
    public var generalSenses: [String] {
        if let dictionary { return dictionary.groups.map { "\($0.pos) \($0.glosses.prefix(3).joined(separator: ", "))" } }
        return otherMeanings
    }
}

/// A lookup request: the word under the cursor plus its context.
public struct LookupRequest: Equatable, Sendable, Hashable {
    public var word: String
    public var sentence: String
    public var context: String
    /// Dictionary senses of the word, passed to the model so it picks a real sense.
    public var dictionary: DictionaryEntry?

    public init(word: String, sentence: String, context: String = "", dictionary: DictionaryEntry? = nil) {
        self.word = word
        self.sentence = sentence
        self.context = context
        self.dictionary = dictionary
    }
}

/// Progress updates emitted by a meaning provider.
public enum LookupEvent: Equatable, Sendable {
    case partial(WordDefinition)
    case complete(WordDefinition)
}

public protocol MeaningProvider: Sendable {
    /// Streams progressively more complete definitions and finishes with `.complete`.
    func lookup(_ request: LookupRequest) -> AsyncThrowingStream<LookupEvent, Error>
}
