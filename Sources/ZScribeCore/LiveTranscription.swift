import Foundation

public struct LiveVADSettings: Hashable, Sendable {
    public var threshold: Double
    public var prefixPaddingMilliseconds: Int
    public var silenceDurationMilliseconds: Int
    public var minimumPauseMilliseconds: Int

    public init(
        threshold: Double,
        prefixPaddingMilliseconds: Int,
        silenceDurationMilliseconds: Int,
        minimumPauseMilliseconds: Int
    ) {
        self.threshold = threshold
        self.prefixPaddingMilliseconds = prefixPaddingMilliseconds
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.minimumPauseMilliseconds = minimumPauseMilliseconds
    }

    public static let microphone = LiveVADSettings(
        threshold: 0.5,
        prefixPaddingMilliseconds: 300,
        silenceDurationMilliseconds: 350,
        minimumPauseMilliseconds: 100
    )

    public static let systemAudio = LiveVADSettings(
        threshold: 0.45,
        prefixPaddingMilliseconds: 300,
        silenceDurationMilliseconds: 250,
        minimumPauseMilliseconds: 50
    )
}

public struct LiveScribeOptions: Hashable, Sendable {
    public var language: String
    public var vadThreshold: Double
    public var prefixPaddingMilliseconds: Int
    public var silenceDurationMilliseconds: Int
    public var minimumPauseMilliseconds: Int
    public var forcedCaptionIntervalMilliseconds: Int

    public init(
        language: String,
        vadThreshold: Double = 0.5,
        prefixPaddingMilliseconds: Int = 300,
        silenceDurationMilliseconds: Int = 350,
        minimumPauseMilliseconds: Int = 100,
        forcedCaptionIntervalMilliseconds: Int = 0
    ) {
        self.language = language
        self.vadThreshold = vadThreshold
        self.prefixPaddingMilliseconds = prefixPaddingMilliseconds
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.minimumPauseMilliseconds = minimumPauseMilliseconds
        self.forcedCaptionIntervalMilliseconds = forcedCaptionIntervalMilliseconds
    }

    public func validate() throws {
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationError("A transcription language is required.")
        }
        guard (0...1).contains(vadThreshold) else {
            throw validationError("VAD threshold must be between 0 and 1.")
        }
        guard (0...5_000).contains(prefixPaddingMilliseconds) else {
            throw validationError("Prefix padding must be between 0 and 5,000 ms.")
        }
        guard (250...10_000).contains(silenceDurationMilliseconds) else {
            throw validationError("Silence duration must be between 250 and 10,000 ms.")
        }
        guard (0...5_000).contains(minimumPauseMilliseconds) else {
            throw validationError("Minimum pause must be between 0 and 5,000 ms.")
        }
        guard forcedCaptionIntervalMilliseconds == 0 ||
            (500...15_000).contains(forcedCaptionIntervalMilliseconds) else {
            throw validationError(
                "Forced caption cadence must be off or between 500 and 15,000 ms."
            )
        }
    }

    private func validationError(_ message: String) -> NSError {
        NSError(
            domain: "ZScribe.Live.Options",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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

    public init(id: UUID = UUID(), number: Int, at: Date = .now, text: String) {
        self.id = id
        self.number = number
        self.at = at
        self.text = text
    }
}
