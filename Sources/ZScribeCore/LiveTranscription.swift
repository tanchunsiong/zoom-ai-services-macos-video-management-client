import Foundation

public struct LiveScribeOptions: Hashable, Sendable {
    public var language: String
    public var vocabularyJSON: String

    public init(
        language: String,
        vocabularyJSON: String = ""
    ) {
        self.language = language
        self.vocabularyJSON = vocabularyJSON
    }

    public func validate() throws {
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationError("A transcription language is required.")
        }
        _ = try ScribeVocabularyJSON.parse(vocabularyJSON)
    }

    private func validationError(_ message: String) -> NSError {
        NSError(
            domain: "ZScribe.Live.Options",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

public enum ScribeVocabularyJSON {
    public static let sample = """
    {
      "phrases": [
        "AIAGW",
        "Zoom AI Companion",
        "ServiceNow"
      ],
      "pronunciations": [
        {
          "phrase": "AIAGW",
          "pronunciation": "A I A gateway"
        }
      ],
      "aliases": [
        {
          "canonical": "Zoom AI Companion",
          "variants": [
            "AI Companion",
            "Zoom Companion"
          ]
        }
      ]
    }
    """

    public static func parse(_ json: String) throws -> [String: Any]? {
        let trimmed = normalized(json)
        guard !trimmed.isEmpty else { return nil }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw vocabularyError("Vocabulary must be valid JSON: \(error.localizedDescription)")
        }
        guard let root = value as? [String: Any] else {
            throw vocabularyError("Vocabulary JSON must contain an object.")
        }

        let vocabulary: [String: Any]
        if let config = root["config"] as? [String: Any] {
            guard let nested = config["vocabulary"] as? [String: Any] else {
                throw vocabularyError("The config object does not contain a vocabulary object.")
            }
            vocabulary = nested
        } else if root.keys.contains("vocabulary") {
            guard let nested = root["vocabulary"] as? [String: Any] else {
                throw vocabularyError("The vocabulary field must contain an object.")
            }
            vocabulary = nested
        } else {
            vocabulary = root
        }

        if let phrases = vocabulary["phrases"] {
            guard let values = phrases as? [Any], values.allSatisfy({ $0 is String }) else {
                throw vocabularyError("phrases must be an array of strings.")
            }
        }
        if let pronunciations = vocabulary["pronunciations"] {
            guard let values = pronunciations as? [[String: Any]], values.allSatisfy({ entry in
                entry["phrase"] is String && entry["pronunciation"] is String
            }) else {
                throw vocabularyError(
                    "pronunciations must contain phrase and pronunciation strings."
                )
            }
        }
        if let aliases = vocabulary["aliases"] {
            guard let values = aliases as? [[String: Any]], values.allSatisfy({ entry in
                guard entry["canonical"] is String,
                      let variants = entry["variants"] as? [Any]
                else { return false }
                return variants.allSatisfy { $0 is String }
            }) else {
                throw vocabularyError(
                    "aliases must contain a canonical string and an array of variant strings."
                )
            }
        }
        return vocabulary
    }

    private static func vocabularyError(_ message: String) -> NSError {
        NSError(
            domain: "ZScribe.Live.Vocabulary",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func normalized(_ json: String) -> String {
        var value = json
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            var lines = trimmed.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                lines.removeLast()
            }
            value = lines.joined(separator: "\n")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LiveScribeEvent: Hashable, Sendable {
    public var type: String
    public var transcript: String?
    public var error: String?
    public var isDelta: Bool

    public init(
        type: String,
        transcript: String? = nil,
        error: String? = nil,
        isDelta: Bool = false
    ) {
        self.type = type
        self.transcript = transcript
        self.error = error
        self.isDelta = isDelta
    }
}

public struct LiveTranscriptSegment: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var number: Int
    public var at: Date
    public var text: String
    public var translation: String?
    public var translationError: String?
    public var isTranslating: Bool

    public init(
        id: UUID = UUID(),
        number: Int,
        at: Date = .now,
        text: String,
        translation: String? = nil,
        translationError: String? = nil,
        isTranslating: Bool = false
    ) {
        self.id = id
        self.number = number
        self.at = at
        self.text = text
        self.translation = translation
        self.translationError = translationError
        self.isTranslating = isTranslating
    }
}
