import Foundation

public enum JobState: String, Codable, CaseIterable, Sendable {
    case queued, preparing, transcribing, translating, summarizing, ready, failed, canceled

    public var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    public var symbol: String {
        switch self {
        case .queued: "clock"
        case .preparing: "waveform.badge.magnifyingglass"
        case .transcribing: "waveform"
        case .translating: "character.book.closed"
        case .summarizing: "text.alignleft"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle"
        }
    }

    public var isProcessing: Bool {
        [.preparing, .transcribing, .translating, .summarizing].contains(self)
    }
}

public struct JobEvent: Codable, Hashable, Sendable {
    public var at: Date
    public var stage: JobState
    public var message: String

    public init(at: Date = .now, stage: JobState, message: String) {
        self.at = at
        self.stage = stage
        self.message = message
    }
}

public struct QueueJob: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourcePath: String
    public var sourceLanguage: String
    public var translationLanguage: String
    public var summarize: Bool
    public var state: JobState
    public var progress: Double
    public var statusMessage: String
    public var error: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var durationSeconds: Double?
    public var hasAudio: Bool?
    public var mediaProbeError: String?
    public var transcriptCharacters: Int
    public var translationInputCharacters: Int
    public var translationOutputCharacters: Int
    public var summaryInputCharacters: Int
    public var summaryOutputCharacters: Int
    public var originalVttPath: String?
    public var translatedVttPath: String?
    public var transcriptJsonPath: String?
    public var summaryPath: String?
    public var reuseExistingTranscript: Bool?
    public var reuseExistingTranslation: Bool?
    public var reuseExistingSummary: Bool?
    public var existingSummaryIsStale: Bool?
    public var events: [JobEvent]

    public init(sourcePath: String, sourceLanguage: String = "en-US",
                translationLanguage: String = "", summarize: Bool = false) {
        id = UUID()
        self.sourcePath = sourcePath
        self.sourceLanguage = sourceLanguage
        self.translationLanguage = translationLanguage
        self.summarize = summarize
        state = .queued
        progress = 0
        statusMessage = "Waiting in queue"
        createdAt = .now
        transcriptCharacters = 0
        translationInputCharacters = 0
        translationOutputCharacters = 0
        summaryInputCharacters = 0
        summaryOutputCharacters = 0
        events = []
    }

    public var displayName: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
    public var canReview: Bool {
        state == .ready && originalVttPath.map(FileManager.default.fileExists) == true
    }
    public var hasTranslation: Bool {
        !translationLanguage.isEmpty && translationLanguage != sourceLanguage
    }
    public var durationLabel: String {
        guard let durationSeconds else { return "--:--" }
        let value = max(0, Int(durationSeconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }

    public mutating func report(_ stage: JobState, progress: Double, _ message: String) {
        state = stage
        self.progress = min(max(progress, 0), 1)
        statusMessage = message
        events.append(JobEvent(stage: stage, message: message))
    }
}

public struct LanguageOption: Identifiable, Hashable, Sendable {
    public let locale: String
    public let name: String
    public var id: String { locale }

    public init(_ locale: String, _ name: String) {
        self.locale = locale
        self.name = name
    }
}

public enum LanguageCatalog {
    public static let all = [
        LanguageOption("en-US", "English"),
        LanguageOption("zh-CN", "Chinese (Simplified)"),
        LanguageOption("ja-JP", "Japanese"),
        LanguageOption("es-ES", "Spanish"),
        LanguageOption("it-IT", "Italian")
    ]

    public static func name(for locale: String) -> String {
        all.first { $0.locale == locale }?.name ?? locale
    }
}

public struct UserSettings: Codable, Hashable, Sendable {
    public var ffmpegPath: String
    public var ffprobePath: String
    public var scribeConcurrency: Int
    public var segmentMinutes: Int
    public var scribeUSDPerMinute: Double
    public var translatorUSDPerMillionCharacters: Double
    public var summarizerUSDPerMillionCharacters: Double
    public var estimatedCharactersPerMinute: Int

    public init(
        ffmpegPath: String = ToolLocator.defaultPath(for: "ffmpeg"),
        ffprobePath: String = ToolLocator.defaultPath(for: "ffprobe"),
        scribeConcurrency: Int = 2,
        segmentMinutes: Int = 15,
        scribeUSDPerMinute: Double = 0.0033,
        translatorUSDPerMillionCharacters: Double = 7.50,
        summarizerUSDPerMillionCharacters: Double = 0.40,
        estimatedCharactersPerMinute: Int = 0
    ) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
        self.scribeConcurrency = scribeConcurrency
        self.segmentMinutes = segmentMinutes
        self.scribeUSDPerMinute = scribeUSDPerMinute
        self.translatorUSDPerMillionCharacters = translatorUSDPerMillionCharacters
        self.summarizerUSDPerMillionCharacters = summarizerUSDPerMillionCharacters
        self.estimatedCharactersPerMinute = estimatedCharactersPerMinute
    }

    public mutating func clamp() {
        scribeConcurrency = min(max(scribeConcurrency, 1), 4)
        segmentMinutes = min(max(segmentMinutes, 1), 30)
        estimatedCharactersPerMinute = min(max(estimatedCharactersPerMinute, 0), 10_000)
        scribeUSDPerMinute = max(0, scribeUSDPerMinute)
        translatorUSDPerMillionCharacters = max(0, translatorUSDPerMillionCharacters)
        summarizerUSDPerMillionCharacters = max(0, summarizerUSDPerMillionCharacters)
    }
}

public struct APICredentials: Hashable, Sendable {
    public var apiKey: String
    public var apiSecret: String
    public var isComplete: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }
}

public struct TranscriptCue: Codable, Identifiable, Hashable, Sendable {
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var id: Int { index }

    public init(index: Int, start: TimeInterval, end: TimeInterval, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
    }

    public func offset(by interval: TimeInterval) -> Self {
        .init(index: index, start: start + interval, end: end + interval, text: text)
    }
}

public struct TranscriptDocument: Codable, Sendable {
    public var language: String
    public var cues: [TranscriptCue]
    public var text: String
    public var requestID: String?
    public var model: String?
}

public struct PreparedAudioPart: Sendable {
    public var index: Int
    public var url: URL
    public var timelineStart: TimeInterval
    public var duration: TimeInterval
    public var mimeType: String

    public init(index: Int, url: URL, timelineStart: TimeInterval,
                duration: TimeInterval, mimeType: String) {
        self.index = index
        self.url = url
        self.timelineStart = timelineStart
        self.duration = duration
        self.mimeType = mimeType
    }
}

public struct MediaProbe: Sendable {
    public var duration: TimeInterval
    public var audioCodec: String
    public var sampleRate: Int
    public var channels: Int
    public var bitRate: Int64?
    public var hasVideo: Bool
    public var audioStreamIndex: Int

    public init(duration: TimeInterval, audioCodec: String, sampleRate: Int,
                channels: Int, bitRate: Int64?, hasVideo: Bool, audioStreamIndex: Int) {
        self.duration = duration
        self.audioCodec = audioCodec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        self.hasVideo = hasVideo
        self.audioStreamIndex = audioStreamIndex
    }
}

public enum TranslationRoute {
    public static func build(source: String, target: String) -> [(String, String)] {
        if source.caseInsensitiveCompare(target) == .orderedSame { return [] }
        if source == "en-US" || target == "en-US" { return [(source, target)] }
        return [(source, "en-US"), ("en-US", target)]
    }
}

public enum ToolLocator {
    public static func defaultPath(for tool: String) -> String {
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        return candidates.first(where: FileManager.default.isExecutableFile) ?? tool
    }
}
