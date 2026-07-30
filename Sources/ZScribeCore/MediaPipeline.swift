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
        job.translationInputCharacters = 0
        job.translationOutputCharacters = 0
        job.summaryInputCharacters = 0
        job.summaryOutputCharacters = 0
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
            job.reuseExistingTranscript = true
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

            job.reuseExistingTranscript = false
            var uploadTarget: Int64?
            var maximumDuration: TimeInterval?
            var documents: [(PreparedAudioPart, TranscriptDocument)] = []
            while documents.isEmpty {
                try? FileManager.default.removeItem(at: work)
                let parts = try await MediaProcessor.extract(
                    source: source,
                    workDirectory: work,
                    probe: probe,
                    settings: settings,
                    uploadTargetBytes: uploadTarget,
                    maximumSegmentDuration: maximumDuration
                ) { fraction in
                    var current = job
                    current.report(
                        .preparing,
                        progress: 0.03 + fraction * 0.17,
                        "Preparing audio segments"
                    )
                    await update(current)
                }
                try Task.checkCancellation()
                job.report(
                    .transcribing,
                    progress: 0.2,
                    "Transcribing \(parts.count) audio segment\(parts.count == 1 ? "" : "s")"
                )
                await update(job)
                do {
                    documents = try await transcribe(
                        parts,
                        language: job.sourceLanguage,
                        credentials: credentials,
                        concurrency: settings.scribeConcurrency
                    ) { completed in
                        job.report(
                            .transcribing,
                            progress: 0.2 + 0.45 * Double(completed) / Double(parts.count),
                            "Transcribed \(completed) of \(parts.count) segments"
                        )
                        await update(job)
                    }
                } catch let error as ZoomAPIError where error.statusCode == 413 {
                    let smaller = (uploadTarget ?? MediaProcessor.uploadTargetBytes) / 2
                    guard smaller >= 10_000_000 else { throw error }
                    uploadTarget = smaller
                    job.report(
                        .preparing,
                        progress: 0.2,
                        "Zoom rejected the audio size; retrying with \(smaller / 1_000_000) MB parts"
                    )
                    await update(job)
                } catch let error as ZoomAPIError where error.statusCode == 503 {
                    let current = maximumDuration ??
                        Double(min(max(settings.segmentMinutes, 1), 30) * 60)
                    let smaller = floor(current / 2)
                    guard smaller >= 60 else { throw error }
                    maximumDuration = smaller
                    job.report(
                        .preparing,
                        progress: 0.2,
                        "Zoom could not process an audio segment; retrying with \(formatMinutes(smaller)) minute parts"
                    )
                    await update(job)
                }
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
            var translatedCues: [TranscriptCue]
            var input = 0
            var output = 0
            if FileManager.default.fileExists(atPath: sidecars.translatedVTT.path),
               let text = try? String(contentsOf: sidecars.translatedVTT, encoding: .utf8),
               !WebVTT.parse(text).isEmpty {
                translatedCues = WebVTT.parse(text)
                job.reuseExistingTranslation = true
                job.report(.translating, progress: 0.82, "Using existing translated captions")
                await update(job)
            } else {
                translatedCues = cues
                job.reuseExistingTranslation = false
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
                        translatedCues,
                        source: step.0,
                        target: step.1,
                        credentials: credentials
                    )
                    translatedCues = result.cues
                    input += result.inputCharacters
                    output += result.outputCharacters
                }
                try WebVTT.write(translatedCues).write(
                    to: sidecars.translatedVTT, atomically: true, encoding: .utf8
                )
            }
            job.translatedVttPath = sidecars.translatedVTT.path
            job.translationInputCharacters = input
            job.translationOutputCharacters = output
            summaryText = translatedCues.map(\.text).joined(separator: "\n")
            summaryLanguage = job.translationLanguage
        }

        if job.summarize {
            if job.existingSummaryIsStale != true,
               FileManager.default.fileExists(atPath: sidecars.summary.path),
               let existing = try? String(contentsOf: sidecars.summary, encoding: .utf8),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let normalized = ZoomAIClient.normalizeSummaryText(existing)
                if normalized != existing {
                    try? normalized.write(to: sidecars.summary, atomically: true, encoding: .utf8)
                }
                job.reuseExistingSummary = true
                job.report(.summarizing, progress: 0.96, "Using existing summary")
                await update(job)
            } else {
                try Task.checkCancellation()
                job.reuseExistingSummary = false
                job.report(
                    .summarizing,
                    progress: 0.84,
                    "Summarizing in \(LanguageCatalog.name(for: summaryLanguage))"
                )
                await update(job)
                let result = try await zoom.summarize(
                    summaryText, language: summaryLanguage, credentials: credentials
                )
                try result.text.write(to: sidecars.summary, atomically: true, encoding: .utf8)
                job.summaryInputCharacters = result.inputCharacters
                job.summaryOutputCharacters = result.outputCharacters
                job.existingSummaryIsStale = false
            }
            job.summaryPath = sidecars.summary.path
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
        let hasOriginal = nonEmptyFile(urls.originalVTT)
        let hasTranslation = nonEmptyFile(urls.translatedVTT)
        let hasSummary = nonEmptyFile(urls.summary)
        let hasTranscriptJSON = nonEmptyFile(urls.transcriptJSON)
        if hasOriginal {
            job.originalVttPath = urls.originalVTT.path
            job.reuseExistingTranscript = true
            job.transcriptJsonPath = hasTranscriptJSON
                ? urls.transcriptJSON.path : nil
            if !job.translationLanguage.isEmpty, hasTranslation {
                job.translatedVttPath = urls.translatedVTT.path
                job.reuseExistingTranslation = true
            }
            if hasSummary {
                job.summaryPath = urls.summary.path
                job.reuseExistingSummary = true
                if let text = try? String(contentsOf: urls.summary, encoding: .utf8) {
                    let normalized = ZoomAIClient.normalizeSummaryText(text)
                    if normalized != text {
                        try? normalized.write(to: urls.summary, atomically: true, encoding: .utf8)
                    }
                }
            }
            let allRequestedExist = (!job.hasTranslation || hasTranslation) &&
                (!job.summarize || hasSummary)
            if allRequestedExist {
                job.completedAt = job.completedAt ?? .now
                job.report(.ready, progress: 1, "All requested outputs already exist")
            } else if job.state == .queued {
                job.statusMessage = "Existing outputs found; only missing tasks will run"
            }
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

    private func transcribe(
        _ parts: [PreparedAudioPart],
        language: String,
        credentials: APICredentials,
        concurrency: Int,
        progress: @escaping (Int) async -> Void
    ) async throws -> [(PreparedAudioPart, TranscriptDocument)] {
        var documents: [(PreparedAudioPart, TranscriptDocument)] = []
        let limit = min(max(concurrency, 1), 4)
        for start in stride(from: 0, to: parts.count, by: limit) {
            let batch = Array(parts[start..<min(start + limit, parts.count)])
            let results = try await withThrowingTaskGroup(
                of: (PreparedAudioPart, TranscriptDocument).self
            ) { group in
                for part in batch {
                    group.addTask { [zoom] in
                        defer { try? FileManager.default.removeItem(at: part.url) }
                        return (
                            part,
                            try await zoom.transcribe(
                                part: part, language: language, credentials: credentials
                            )
                        )
                    }
                }
                var values: [(PreparedAudioPart, TranscriptDocument)] = []
                for try await value in group { values.append(value) }
                return values
            }
            documents += results
            await progress(documents.count)
        }
        return documents
    }

    private static func nonEmptyFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } == true
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        return minutes.rounded() == minutes
            ? String(format: "%.0f", minutes)
            : String(format: "%.2f", minutes)
    }
}
