import Foundation

public final class MediaPipeline {
    private let zoom: ZoomAIClient
    private let paths: AppPaths

    public init(zoom: ZoomAIClient = ZoomAIClient(), paths: AppPaths) {
        self.zoom = zoom
        self.paths = paths
    }

    public func process(
        _ sourceJob: QueueJob,
        settings: UserSettings,
        credentials: APICredentials,
        update: @escaping (QueueJob) async -> Void
    ) async throws -> QueueJob {
        var job = sourceJob
        job.startedAt = .now
        job.completedAt = nil
        job.error = nil
        let work = paths.work.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        defer { try? FileManager.default.removeItem(at: work) }

        let source = URL(fileURLWithPath: job.sourcePath)
        let sidecars = Self.sidecarURLs(for: source, translationLanguage: job.translationLanguage)
        var cues: [TranscriptCue]
        if FileManager.default.fileExists(atPath: sidecars.originalVTT.path),
           let existing = try? String(contentsOf: sidecars.originalVTT, encoding: .utf8),
           !WebVTT.parse(existing).isEmpty {
            cues = WebVTT.parse(existing)
            job.originalVttPath = sidecars.originalVTT.path
            job.transcriptJsonPath = FileManager.default.fileExists(atPath: sidecars.transcriptJSON.path)
                ? sidecars.transcriptJSON.path : nil
            job.report(.preparing, progress: 0.65, "Using existing original captions")
            await update(job)
        } else {
            job.report(.preparing, progress: 0.02, "Inspecting media")
            await update(job)
            let probe = try await MediaProcessor.probe(url: source, settings: settings)
            job.durationSeconds = probe.duration
            job.hasAudio = !probe.audioCodec.isEmpty
            guard job.hasAudio == true else {
                throw NSError(domain: "ZScribe.Media", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "The selected file has no audio stream."])
            }

            let parts = try await MediaProcessor.extract(
                source: source, workDirectory: work, probe: probe, settings: settings
            ) { fraction in
                var current = job
                current.report(.preparing, progress: 0.03 + fraction * 0.17, "Preparing audio segments")
                await update(current)
            }
            try Task.checkCancellation()

            job.report(.transcribing, progress: 0.2, "Transcribing \(parts.count) audio segment\(parts.count == 1 ? "" : "s")")
            await update(job)
            var documents: [(PreparedAudioPart, TranscriptDocument)] = []
            let concurrency = min(max(settings.scribeConcurrency, 1), 4)
            for start in stride(from: 0, to: parts.count, by: concurrency) {
                let batch = Array(parts[start..<min(start + concurrency, parts.count)])
                let results = try await withThrowingTaskGroup(
                    of: (PreparedAudioPart, TranscriptDocument).self
                ) { group in
                    for part in batch {
                        group.addTask { [zoom] in
                            defer { try? FileManager.default.removeItem(at: part.url) }
                            let document = try await zoom.transcribe(
                                part: part, language: job.sourceLanguage, credentials: credentials
                            )
                            return (part, document)
                        }
                    }
                    var values: [(PreparedAudioPart, TranscriptDocument)] = []
                    for try await value in group { values.append(value) }
                    return values
                }
                documents += results
                job.report(
                    .transcribing,
                    progress: 0.2 + 0.45 * Double(documents.count) / Double(parts.count),
                    "Transcribed \(documents.count) of \(parts.count) segments"
                )
                await update(job)
            }

            cues = documents.sorted(by: { $0.0.index < $1.0.index }).flatMap { part, document in
                document.cues.map { $0.offset(by: part.timelineStart) }
            }
            cues = cues.sorted(by: { $0.start < $1.start }).enumerated().map {
                TranscriptCue(index: $0.offset + 1, start: $0.element.start,
                              end: $0.element.end, text: $0.element.text)
            }
            let transcriptText = cues.map(\.text).joined(separator: "\n")
            let transcript = TranscriptDocument(
                language: job.sourceLanguage, cues: cues, text: transcriptText,
                requestID: documents.first?.1.requestID, model: documents.first?.1.model
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try WebVTT.write(cues).write(to: sidecars.originalVTT, atomically: true, encoding: .utf8)
            try encoder.encode(transcript).write(to: sidecars.transcriptJSON, options: .atomic)
            job.originalVttPath = sidecars.originalVTT.path
            job.transcriptJsonPath = sidecars.transcriptJSON.path
        }
        let transcriptText = cues.map(\.text).joined(separator: "\n")
        job.transcriptCharacters = transcriptText.count
        var summaryText = transcriptText
        var summaryLanguage = job.sourceLanguage

        if job.hasTranslation {
            var translatedCues = cues
            var input = 0
            var output = 0
            let route = TranslationRoute.build(
                source: job.sourceLanguage, target: job.translationLanguage
            )
            for (index, step) in route.enumerated() {
                try Task.checkCancellation()
                job.report(
                    .translating,
                    progress: 0.67 + 0.14 * Double(index) / Double(route.count),
                    "Translating \(LanguageCatalog.name(for: step.0)) to \(LanguageCatalog.name(for: step.1))"
                )
                await update(job)
                let result = try await zoom.translateCues(
                    translatedCues, source: step.0, target: step.1, credentials: credentials
                )
                translatedCues = result.cues
                input += result.inputCharacters
                output += result.outputCharacters
            }
            try WebVTT.write(translatedCues).write(
                to: sidecars.translatedVTT, atomically: true, encoding: .utf8
            )
            job.translatedVttPath = sidecars.translatedVTT.path
            job.translationInputCharacters = input
            job.translationOutputCharacters = output
            summaryText = translatedCues.map(\.text).joined(separator: "\n")
            summaryLanguage = job.translationLanguage
        }

        if job.summarize {
            try Task.checkCancellation()
            job.report(.summarizing, progress: 0.84, "Creating summary")
            await update(job)
            let result = try await zoom.summarize(
                summaryText, language: summaryLanguage, credentials: credentials
            )
            try result.text.write(to: sidecars.summary, atomically: true, encoding: .utf8)
            job.summaryPath = sidecars.summary.path
            job.summaryInputCharacters = result.inputCharacters
            job.summaryOutputCharacters = result.outputCharacters
        }

        job.completedAt = .now
        job.report(.ready, progress: 1, "Transcript is ready to review")
        await update(job)
        return job
    }

    public func probe(_ job: QueueJob, settings: UserSettings) async -> QueueJob {
        var result = job
        do {
            let probe = try await MediaProcessor.probe(
                url: URL(fileURLWithPath: job.sourcePath), settings: settings
            )
            result.durationSeconds = probe.duration
            result.hasAudio = !probe.audioCodec.isEmpty
            result.mediaProbeError = nil
            if result.hasAudio == false { result.statusMessage = "No audio stream detected" }
        } catch {
            result.mediaProbeError = error.localizedDescription
        }
        return result
    }

    public static func applyExistingOutputs(to sourceJob: QueueJob) -> QueueJob {
        var job = sourceJob
        let urls = sidecarURLs(
            for: URL(fileURLWithPath: job.sourcePath),
            translationLanguage: job.translationLanguage
        )
        if FileManager.default.fileExists(atPath: urls.originalVTT.path) {
            job.originalVttPath = urls.originalVTT.path
            job.transcriptJsonPath = FileManager.default.fileExists(atPath: urls.transcriptJSON.path)
                ? urls.transcriptJSON.path : nil
            if !job.translationLanguage.isEmpty,
               FileManager.default.fileExists(atPath: urls.translatedVTT.path) {
                job.translatedVttPath = urls.translatedVTT.path
            }
            if FileManager.default.fileExists(atPath: urls.summary.path) {
                job.summaryPath = urls.summary.path
            }
            job.report(.ready, progress: 1, "Existing transcript found")
        }
        return job
    }

    public static func sidecarURLs(
        for source: URL, translationLanguage: String
    ) -> (originalVTT: URL, translatedVTT: URL, transcriptJSON: URL, summary: URL) {
        let base = source.deletingPathExtension()
        let parent = source.deletingLastPathComponent()
        let name = base.lastPathComponent
        return (
            parent.appendingPathComponent("\(name).vtt"),
            parent.appendingPathComponent("\(name).translated-\(translationLanguage).vtt"),
            parent.appendingPathComponent("\(name).transcript.json"),
            parent.appendingPathComponent("\(name).summary.md")
        )
    }
}
