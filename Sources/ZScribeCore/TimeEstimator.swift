import Foundation

public struct TimeBreakdown: Sendable {
    public var scribe: TimeInterval?
    public var translate: TimeInterval?
    public var summarize: TimeInterval?
    public var total: TimeInterval? {
        guard let scribe, let translate, let summarize else { return nil }
        return scribe + translate + summarize
    }

    public init(
        scribe: TimeInterval?,
        translate: TimeInterval?,
        summarize: TimeInterval?
    ) {
        self.scribe = scribe
        self.translate = translate
        self.summarize = summarize
    }
}

public struct JobTimeComparison: Sendable {
    public var estimate: TimeBreakdown
    public var actual: TimeBreakdown
}

public struct TimeRate: Sendable {
    public var interceptSeconds: Double
    public var secondsPerUnit: Double
    public var sampleCount: Int

    public func estimate(units: Double) -> TimeInterval {
        max(0, interceptSeconds + max(0, units) * secondsPerUnit)
    }
}

public struct JobTimeCalibration: Sendable {
    public var scribe: TimeRate
    public var translate: TimeRate
    public var summarize: TimeRate
    public var scribeByExtension: [String: TimeRate]

    public static let `default` = JobTimeCalibration(
        scribe: TimeRate(interceptSeconds: 12, secondsPerUnit: 18, sampleCount: 0),
        translate: TimeRate(interceptSeconds: 3, secondsPerUnit: 0.6, sampleCount: 0),
        summarize: TimeRate(interceptSeconds: 6, secondsPerUnit: 0.6, sampleCount: 0),
        scribeByExtension: [:]
    )

    public func scribeRate(for job: QueueJob) -> TimeRate {
        scribeByExtension[
            URL(fileURLWithPath: job.sourcePath).pathExtension.lowercased()
        ] ?? scribe
    }

    public static func learn(from jobs: [QueueJob]) -> JobTimeCalibration {
        struct Observation {
            let key: String
            let units: Double
            let seconds: Double
        }
        let completed = jobs.compactMap { job -> (QueueJob, TimeBreakdown)? in
            guard job.completedAt != nil else { return nil }
            return (job, TimeEstimator.actual(for: job))
        }
        let scribeObservations = completed.compactMap { job, actual -> Observation? in
            guard let duration = job.durationSeconds, duration > 0,
                  let seconds = actual.scribe, seconds > 0 else { return nil }
            return Observation(
                key: URL(fileURLWithPath: job.sourcePath).pathExtension.lowercased(),
                units: duration / 60,
                seconds: seconds
            )
        }
        let translationObservations = completed.compactMap { job, actual -> Observation? in
            let characters = job.translationInputCharacters + job.translationOutputCharacters
            guard characters > 0, let seconds = actual.translate, seconds > 0 else { return nil }
            return Observation(key: "", units: Double(characters) / 1_000, seconds: seconds)
        }
        let summaryObservations = completed.compactMap { job, actual -> Observation? in
            guard job.summaryInputCharacters > 0,
                  let seconds = actual.summarize, seconds > 0 else { return nil }
            return Observation(
                key: "",
                units: Double(job.summaryInputCharacters) / 1_000,
                seconds: seconds
            )
        }
        let grouped = Dictionary(grouping: scribeObservations, by: \.key)
        let byExtension = grouped.compactMapValues { observations in
            observations.count >= 3 ? fit(observations, fallback: Self.default.scribe) : nil
        }
        return JobTimeCalibration(
            scribe: fit(scribeObservations, fallback: Self.default.scribe),
            translate: fit(translationObservations, fallback: Self.default.translate),
            summarize: fit(summaryObservations, fallback: Self.default.summarize),
            scribeByExtension: byExtension
        )

        func fit(_ values: [Observation], fallback: TimeRate) -> TimeRate {
            guard !values.isEmpty else { return fallback }
            if values.count == 1 {
                return TimeRate(
                    interceptSeconds: values[0].seconds,
                    secondsPerUnit: 0,
                    sampleCount: 1
                )
            }
            let averageUnits = values.map(\.units).reduce(0, +) / Double(values.count)
            let averageSeconds = values.map(\.seconds).reduce(0, +) / Double(values.count)
            let denominator = values.reduce(0) {
                $0 + pow($1.units - averageUnits, 2)
            }
            let slope = denominator <= .ulpOfOne
                ? fallback.secondsPerUnit
                : values.reduce(0) {
                    $0 + ($1.units - averageUnits) * ($1.seconds - averageSeconds)
                } / denominator
            return TimeRate(
                interceptSeconds: min(max(averageSeconds - slope * averageUnits, 0), 60),
                secondsPerUnit: min(max(slope, 0.01), fallback.secondsPerUnit * 4),
                sampleCount: values.count
            )
        }
    }
}

public enum TimeEstimator {
    public static func compare(
        _ job: QueueJob,
        settings: UserSettings,
        calibration: JobTimeCalibration = .default
    ) -> JobTimeComparison {
        let sourceCharacters = CostEstimator.estimatedSourceCharacters(job, settings: settings)
        let routeSteps = job.hasTranslation
            ? TranslationRoute.build(
                source: job.sourceLanguage, target: job.translationLanguage
            ).count
            : 0
        let translationCharacters = sourceCharacters * 2 * routeSteps
        let summaryCharacters = job.summarize
            ? Int(ceil(Double(sourceCharacters) * 1.21))
            : 0
        return JobTimeComparison(
            estimate: TimeBreakdown(
                scribe: estimatedScribe(job, calibration: calibration),
                translate: estimatedTranslation(
                    job,
                    characters: translationCharacters,
                    routeSteps: routeSteps,
                    calibration: calibration
                ),
                summarize: estimatedSummary(
                    job,
                    characters: summaryCharacters,
                    calibration: calibration
                )
            ),
            actual: actual(for: job)
        )
    }

    public static func actual(for job: QueueJob) -> TimeBreakdown {
        TimeBreakdown(
            scribe: job.reuseExistingTranscript == true || job.hasAudio == false
                ? 0
                : actualStage(job, stages: [.preparing, .transcribing]),
            translate: !job.hasTranslation || job.reuseExistingTranslation == true
                ? 0
                : actualStage(job, stages: [.translating]),
            summarize: !job.summarize || job.reuseExistingSummary == true
                ? 0
                : actualStage(job, stages: [.summarizing])
        )
    }

    public static func format(_ interval: TimeInterval?) -> String {
        guard let interval else { return "--" }
        let seconds = max(0, Int(ceil(interval)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds >= 3_600 {
            return String(format: "%dh %02dm", seconds / 3_600, seconds / 60 % 60)
        }
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    public static func aggregateFormat(_ values: [TimeInterval?]) -> String {
        guard !values.isEmpty else { return format(0) }
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return "--" }
        return format(known.reduce(0, +)) + (known.count == values.count ? "" : "+")
    }

    private static func estimatedScribe(
        _ job: QueueJob, calibration: JobTimeCalibration
    ) -> TimeInterval? {
        if job.reuseExistingTranscript == true || job.hasAudio == false { return 0 }
        guard let duration = job.durationSeconds, duration > 0 else { return nil }
        let rate = calibration.scribeRate(for: job)
        return rate.sampleCount > 0
            ? rate.estimate(units: duration / 60)
            : 12 + duration * 0.30
    }

    private static func estimatedTranslation(
        _ job: QueueJob,
        characters: Int,
        routeSteps: Int,
        calibration: JobTimeCalibration
    ) -> TimeInterval? {
        if routeSteps == 0 || job.reuseExistingTranslation == true { return 0 }
        guard characters > 0 else { return nil }
        return calibration.translate.sampleCount > 0
            ? calibration.translate.estimate(units: Double(characters) / 1_000)
            : Double(routeSteps) * 3 + Double(characters) / 1_000 * 0.60
    }

    private static func estimatedSummary(
        _ job: QueueJob,
        characters: Int,
        calibration: JobTimeCalibration
    ) -> TimeInterval? {
        if !job.summarize || job.reuseExistingSummary == true { return 0 }
        guard characters > 0 else { return nil }
        return calibration.summarize.sampleCount > 0
            ? calibration.summarize.estimate(units: Double(characters) / 1_000)
            : 6 + Double(characters) / 1_000 * 0.60
    }

    private static func actualStage(
        _ job: QueueJob, stages: Set<JobState>
    ) -> TimeInterval? {
        guard let startedAt = job.startedAt, let completedAt = job.completedAt else {
            return nil
        }
        let events = job.events
            .filter { $0.at >= startedAt && $0.at <= completedAt }
            .sorted { $0.at < $1.at }
        var total: TimeInterval = 0
        var found = false
        for index in events.indices {
            guard stages.contains(events[index].stage),
                  index == events.startIndex || !stages.contains(events[index - 1].stage)
            else { continue }
            let end = events[(index + 1)...].first {
                !stages.contains($0.stage)
            }?.at ?? completedAt
            guard end > events[index].at else { continue }
            total += end.timeIntervalSince(events[index].at)
            found = true
        }
        return found ? total : nil
    }
}
