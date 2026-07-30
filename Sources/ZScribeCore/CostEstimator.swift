import Foundation

public struct CostBreakdown: Sendable {
    public var scribe: Double
    public var translate: Double
    public var summarize: Double
    public var total: Double { scribe + translate + summarize }

    public init(scribe: Double, translate: Double, summarize: Double) {
        self.scribe = scribe
        self.translate = translate
        self.summarize = summarize
    }
}

public enum CostEstimator {
    public static func estimate(_ job: QueueJob, settings: UserSettings) -> CostBreakdown {
        let minutes = max(0, job.durationSeconds ?? 0) / 60
        let sourceCharacters = estimatedSourceCharacters(job, settings: settings)
        let routeCount = TranslationRoute.build(
            source: job.sourceLanguage, target: job.translationLanguage
        ).count
        let translationCharacters = job.hasTranslation ? sourceCharacters * 2 * routeCount : 0
        let summaryCharacters = job.summarize ? Int(ceil(Double(sourceCharacters) * 1.21)) : 0
        return CostBreakdown(
            scribe: job.reuseExistingTranscript == true
                ? 0 : minutes * settings.scribeUSDPerMinute,
            translate: job.reuseExistingTranslation == true
                ? 0
                : Double(translationCharacters) / 1_000_000 *
                    settings.translatorUSDPerMillionCharacters,
            summarize: job.reuseExistingSummary == true
                ? 0
                : Double(summaryCharacters) / 1_000_000 *
                    settings.summarizerUSDPerMillionCharacters
        )
    }

    public static func actual(_ job: QueueJob, settings: UserSettings) -> CostBreakdown? {
        guard job.completedAt != nil else { return nil }
        let scribe = job.reuseExistingTranscript == true
            ? 0
            : max(0, job.durationSeconds ?? 0) / 60 * settings.scribeUSDPerMinute
        let translationUnits = job.translationInputCharacters + job.translationOutputCharacters
        let summaryUnits = job.summaryInputCharacters + job.summaryOutputCharacters
        return CostBreakdown(
            scribe: scribe,
            translate: job.reuseExistingTranslation == true
                ? 0
                : Double(translationUnits) / 1_000_000 * settings.translatorUSDPerMillionCharacters,
            summarize: job.reuseExistingSummary == true
                ? 0
                : Double(summaryUnits) / 1_000_000 * settings.summarizerUSDPerMillionCharacters
        )
    }

    public static func format(_ value: Double) -> String {
        value > 0 && value < 0.01
            ? String(format: "$%.4f", value)
            : String(format: "$%.2f", value)
    }

    public static func estimatedSourceCharacters(
        _ job: QueueJob, settings: UserSettings
    ) -> Int {
        if job.hasAudio == false { return 0 }
        if job.transcriptCharacters > 0 { return job.transcriptCharacters }
        let minutes = max(0, job.durationSeconds ?? 0) / 60
        return Int(ceil(
            minutes * Double(charactersPerMinute(job.sourceLanguage, settings: settings))
        ))
    }

    private static func charactersPerMinute(_ language: String, settings: UserSettings) -> Int {
        if settings.estimatedCharactersPerMinute > 0 { return settings.estimatedCharactersPerMinute }
        return switch language {
        case "zh-CN", "ja-JP": 300
        case "es-ES": 900
        case "it-IT": 850
        default: 800
        }
    }
}
