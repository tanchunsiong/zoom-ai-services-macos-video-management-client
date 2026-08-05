import Foundation
import ZScribeCore

@main
struct CoreChecks {
    static func main() async throws {
        try webVTTRoundTrip()
        translationRoutingBridgesThroughEnglish()
        try jwtContainsExpectedClaims()
        try localCredentialStoreRoundTrip()
        try livePCMFramesAndLevels()
        try liveSessionContractAndEvents()
        try await scribeRequestMatchesContract()
        try streamedScribeBodyRoundTripsMultipleChunks()
        try await queueSearchCoversAllArtifactsAndInvalidatesCache()
        try recursiveMediaDiscoveryPreservesDuplicates()
        audioProfilesMatchZoomCompatibleContainers()
        segmentDurationObservesUploadTarget()
        languageAwareCostEstimate()
        try summaryNormalizationRemovesDuplicateSections()
        try partialOutputsResumeOnlyMissingWork()
        try processingTimeEstimatesAndCalibration()
        try playbackCompatibilityArgumentsPreserveVideo()
        try interruptedQueueStateIsRecovered()
        try await processCancellationTerminatesChild()
        print("All ZScribeCore checks passed.")
    }

    static func webVTTRoundTrip() throws {
        let cues = [
            TranscriptCue(index: 1, start: 1.25, end: 3.5, text: "Hello"),
            TranscriptCue(index: 2, start: 3.5, end: 65.001, text: "Second line")
        ]
        let output = WebVTT.write(cues)
        try expect(output.hasPrefix("WEBVTT\n\n"), "VTT header")
        try expect(output.contains("00:00:01.250 --> 00:00:03.500"), "VTT timestamp")
        try expect(WebVTT.parse(output) == cues, "VTT round trip")
    }

    static func translationRoutingBridgesThroughEnglish() {
        let route = TranslationRoute.build(source: "ja-JP", target: "zh-CN")
        precondition(route.count == 2)
        precondition(route[0].0 == "ja-JP" && route[0].1 == "en-US")
        precondition(route[1].0 == "en-US" && route[1].1 == "zh-CN")
        precondition(TranslationRoute.build(source: "en-US", target: "it-IT").count == 1)
        precondition(TranslationRoute.build(source: "en-US", target: "en-US").isEmpty)
    }

    static func jwtContainsExpectedClaims() throws {
        let token = try ZoomJWT.create(
            credentials: APICredentials(apiKey: "key", apiSecret: "secret"),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let pieces = token.split(separator: ".")
        try expect(pieces.count == 3, "JWT shape")
        guard let payload = decodeBase64URL(String(pieces[1])),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw CheckFailure("JWT payload") }
        try expect(claims["iss"] as? String == "key", "JWT issuer")
        try expect(claims["iat"] as? Int == 1_699_999_970, "JWT issued-at")
        try expect(claims["exp"] as? Int == 1_700_003_570, "JWT expiry")
    }

    static func localCredentialStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zscribe-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(root: root)
        let store = FileCredentialStore(paths: paths)
        let credentials = APICredentials(apiKey: "local-key", apiSecret: "local-secret")
        try store.save(credentials)
        let loaded = try store.load()
        try expect(loaded == credentials, "Local credentials round trip")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.credentials.path
        )
        try expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "Local credential permissions"
        )
        try store.clear()
        let cleared = try store.load()
        try expect(cleared == nil, "Local credentials removed")
    }

    static func livePCMFramesAndLevels() throws {
        var assembler = PCM16FrameAssembler(frameBytes: 8)
        try expect(assembler.append(Data([0, 1, 2, 3, 4, 5])).isEmpty, "Live partial frame")
        let frames = assembler.append(Data([6, 7, 8, 9, 10, 11]))
        try expect(
            frames == [Data([0, 1, 2, 3, 4, 5, 6, 7])],
            "Live exact PCM frame"
        )
        try expect(
            assembler.drain() == Data([8, 9, 10, 11]),
            "Live PCM remainder"
        )

        var halfScale = Data()
        for _ in 0..<160 {
            var sample = Int16(16_384).littleEndian
            withUnsafeBytes(of: &sample) { halfScale.append(contentsOf: $0) }
        }
        let reading = PCM16AudioProcessor().process(
            &halfScale,
            automaticGain: false
        )
        try expect(abs(reading.peakDBFS - -6.0206) < 0.01, "Live peak dBFS")
        try expect(abs(reading.rmsDBFS - -6.0206) < 0.01, "Live RMS dBFS")
        try expect(!reading.isClipping, "Live non-clipping input")

        var quiet = Data()
        for _ in 0..<160 {
            var sample = Int16(500).littleEndian
            withUnsafeBytes(of: &sample) { quiet.append(contentsOf: $0) }
        }
        let gainReading = PCM16AudioProcessor().process(&quiet, automaticGain: true)
        let amplified = quiet.withUnsafeBytes {
            Int16(littleEndian: $0.loadUnaligned(as: Int16.self))
        }
        try expect(gainReading.appliedGain > 1 && amplified > 500, "Live automatic gain")
        try expect(
            PCM16AudioProcessor.normalizedMeter(-30) == 0.5,
            "Live normalized meter"
        )
    }

    static func liveSessionContractAndEvents() throws {
        let vocabularyJSON = #"""
        {
          "phrases": ["AIAGW", "Zoom AI Companion"],
          "pronunciations": [
            {"phrase": "AIAGW", "pronunciation": "A I A gateway"}
          ],
          "aliases": [
            {"canonical": "Zoom AI Companion", "variants": ["AI Companion"]}
          ]
        }
        """#
        let options = LiveScribeOptions(
            language: "ja-JP",
            vocabularyJSON: vocabularyJSON
        )
        let data = Data(try ZoomLiveScribeClient.sessionUpdateJSON(options).utf8)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let vocabulary = root?["vocabulary"] as? [String: Any]
        try expect(root?["type"] as? String == "session.update", "Live session type")
        try expect(root?["input_audio_format"] as? String == "pcm16", "Live PCM format")
        try expect(root?["language"] as? String == "ja-JP", "Live language")
        try expect(root?["turn_detection"] == nil, "Live VAD configuration omitted")
        try expect(
            vocabulary?["phrases"] as? [String] == ["AIAGW", "Zoom AI Companion"],
            "Live vocabulary phrases"
        )

        let fullConfig = #"""
        {
          "config": {
            "language": "en-US",
            "vocabulary": {"phrases": ["ServiceNow"]}
          },
          "reference_id": "customer-request-123"
        }
        """#
        let extracted = try ScribeVocabularyJSON.parse(fullConfig)
        try expect(
            extracted?["phrases"] as? [String] == ["ServiceNow"],
            "Live full config vocabulary extraction"
        )
        let sample = try ScribeVocabularyJSON.parse(ScribeVocabularyJSON.sample)
        try expect(
            sample?["phrases"] as? [String] == [
                "AIAGW", "Zoom AI Companion", "ServiceNow"
            ],
            "Live default vocabulary sample"
        )
        let fenced = try ScribeVocabularyJSON.parse(
            """
            ```json
            {“phrases”:[“ServiceNow”]}
            ```
            """
        )
        try expect(
            fenced?["phrases"] as? [String] == ["ServiceNow"],
            "Live fenced smart-quote vocabulary"
        )
        do {
            try LiveScribeOptions(
                language: "en-US",
                vocabularyJSON: #"{"phrases":"AIAGW"}"#
            ).validate()
            throw CheckFailure("Live invalid vocabulary rejection")
        } catch let error as CheckFailure {
            throw error
        } catch {
            try expect(
                error.localizedDescription.contains("array of strings"),
                "Live vocabulary validation"
            )
        }

        let completed = try ZoomLiveScribeClient.parseServerEvent(
            #"{"type":"transcription.completed","transcript":"Hello live"}"#
        )
        let delta = try ZoomLiveScribeClient.parseServerEvent(
            #"{"type":"transcription.delta","data":{"delta":"words in progress "}}"#
        )
        let error = try ZoomLiveScribeClient.parseServerEvent(
            #"{"type":"error","error":{"message":"Invalid session"}}"#
        )
        try expect(completed.transcript == "Hello live", "Live completed transcript")
        try expect(delta.transcript == "words in progress " && delta.isDelta, "Live delta")
        try expect(error.error == "Invalid session", "Live structured error")
    }

    static func audioProfilesMatchZoomCompatibleContainers() {
        precondition(MediaProcessor.profile(for: "aac").fileExtension == "m4a")
        precondition(MediaProcessor.profile(for: "aac").streamCopy)
        precondition(MediaProcessor.profile(for: "mp3").codec == "copy")
        precondition(MediaProcessor.profile(for: "ac3").codec == "libmp3lame")
        precondition(!MediaProcessor.profile(for: "wma").streamCopy)
    }

    static func queueSearchCoversAllArtifactsAndInvalidatesCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zscribe-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let filenameJob = QueueJob(sourcePath: directory.appendingPathComponent("Aurora launch.mp4").path)
        var transcriptJob = QueueJob(sourcePath: directory.appendingPathComponent("transcript.mp4").path)
        var translatedJob = QueueJob(
            sourcePath: directory.appendingPathComponent("translated.mp4").path,
            translationLanguage: "zh-CN"
        )
        var jsonJob = QueueJob(sourcePath: directory.appendingPathComponent("json.mp4").path)
        var summaryJob = QueueJob(sourcePath: directory.appendingPathComponent("summary.mp4").path)
        let unrelatedJob = QueueJob(sourcePath: directory.appendingPathComponent("unrelated.mp4").path)

        let transcriptURLs = MediaPipeline.sidecarURLs(
            for: URL(fileURLWithPath: transcriptJob.sourcePath),
            translationLanguage: ""
        )
        try "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nThe aurora is visible."
            .write(to: transcriptURLs.originalVTT, atomically: true, encoding: .utf8)
        transcriptJob.originalVttPath = transcriptURLs.originalVTT.path

        let translatedURLs = MediaPipeline.sidecarURLs(
            for: URL(fileURLWithPath: translatedJob.sourcePath),
            translationLanguage: "zh-CN"
        )
        try "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nAurora translated"
            .write(to: translatedURLs.translatedVTT, atomically: true, encoding: .utf8)
        translatedJob.translatedVttPath = translatedURLs.translatedVTT.path

        let jsonURLs = MediaPipeline.sidecarURLs(
            for: URL(fileURLWithPath: jsonJob.sourcePath),
            translationLanguage: ""
        )
        try #"{"text":"AURORA from transcript JSON"}"#
            .write(to: jsonURLs.transcriptJSON, atomically: true, encoding: .utf8)
        jsonJob.transcriptJsonPath = jsonURLs.transcriptJSON.path

        let summaryURLs = MediaPipeline.sidecarURLs(
            for: URL(fileURLWithPath: summaryJob.sourcePath),
            translationLanguage: ""
        )
        try "# Summary\nThe aurora project launched."
            .write(to: summaryURLs.summary, atomically: true, encoding: .utf8)
        summaryJob.summaryPath = summaryURLs.summary.path

        let jobs = [
            filenameJob, transcriptJob, translatedJob, jsonJob, summaryJob, unrelatedJob
        ]
        let index = QueueSearchIndex()
        let matches = await index.findMatches(in: jobs, query: "aUrOrA")
        try expect(
            matches == Set(jobs.dropLast().map(\.id)),
            "Search filenames and all sidecar formats"
        )

        let cacheJob = QueueJob(sourcePath: directory.appendingPathComponent("cache.mp4").path)
        let cacheURLs = MediaPipeline.sidecarURLs(
            for: URL(fileURLWithPath: cacheJob.sourcePath),
            translationLanguage: ""
        )
        try "cachedone".write(to: cacheURLs.summary, atomically: true, encoding: .utf8)
        let initialCacheMatches = await index.findMatches(
            in: [cacheJob], query: "cachedone"
        )
        try expect(
            initialCacheMatches == [cacheJob.id],
            "Search cache initial read"
        )
        try "cachedtwo".write(to: cacheURLs.summary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: cacheURLs.summary.path
        )
        let updatedCacheMatches = await index.findMatches(
            in: [cacheJob], query: "cachedtwo"
        )
        try expect(
            updatedCacheMatches == [cacheJob.id],
            "Search cache invalidation"
        )
    }

    static func scribeRequestMatchesContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = ZoomAIClient(session: URLSession(configuration: configuration))
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp3")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let part = PreparedAudioPart(
            index: 0, url: audio, timelineStart: 0, duration: 1, mimeType: "audio/mpeg"
        )
        _ = try await client.transcribe(
            part: part, language: "en-US",
            credentials: APICredentials(apiKey: "key", apiSecret: "secret")
        )
        let body = try MockURLProtocol.lastBody()
        let root = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let file = root?["file"] as? String
        let config = root?["config"] as? [String: Any]
        try expect(file == "data:audio/mpeg;base64,AQID", "Scribe file data URI")
        try expect(config?["language"] as? String == "en-US", "Scribe language config")
        try expect(config?["channel_separation"] as? Bool == false, "Scribe channel config")
    }

    static func streamedScribeBodyRoundTripsMultipleChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("audio.mp3")
        let body = directory.appendingPathComponent("body.json")
        let original = Data((0..<100_000).map { UInt8($0 % 251) })
        try original.write(to: audio)
        try ZoomAIClient.writeScribeBody(
            audioURL: audio,
            mimeType: "audio/mpeg",
            language: "ja-JP",
            to: body
        )
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: body)
        ) as? [String: Any]
        let dataURI = try require(root?["file"] as? String, "Streamed Scribe file")
        let encoded = try require(
            dataURI.components(separatedBy: "base64,").last,
            "Streamed Scribe Base64"
        )
        try expect(Data(base64Encoded: encoded) == original, "Streamed Base64 round trip")
        let config = root?["config"] as? [String: Any]
        try expect(config?["language"] as? String == "ja-JP", "Streamed Scribe config")
    }

    static func recursiveMediaDiscoveryPreservesDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.mp4")
        let second = nested.appendingPathComponent("second.MP3")
        let ignored = nested.appendingPathComponent("notes.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        try Data().write(to: ignored)
        let recursive = MediaDiscovery.expand([directory])
        try expect(
            Set(recursive.map(\.lastPathComponent)) == ["first.mp4", "second.MP3"],
            "Recursive media discovery"
        )
        let duplicates = MediaDiscovery.expand([first, first])
        try expect(duplicates == [first, first], "Duplicate imports preserved")
    }

    static func segmentDurationObservesUploadTarget() {
        let probe = MediaProbe(
            duration: 7_200, audioCodec: "mp3", sampleRate: 48_000,
            channels: 2, bitRate: 1_000_000, hasVideo: false, audioStreamIndex: 0
        )
        let duration = MediaProcessor.segmentDuration(
            probe: probe, profile: MediaProcessor.profile(for: "mp3"), requested: 900
        )
        precondition(abs(duration - 640) < 0.001)
        let smallerUpload = MediaProcessor.segmentDuration(
            probe: probe,
            profile: MediaProcessor.profile(for: "mp3"),
            requested: 900,
            uploadTargetBytes: 40_000_000
        )
        precondition(abs(smallerUpload - 320) < 0.001)
        let shorterSegment = MediaProcessor.segmentDuration(
            probe: probe,
            profile: MediaProcessor.profile(for: "mp3"),
            requested: 120,
            uploadTargetBytes: 80_000_000
        )
        precondition(abs(shorterSegment - 120) < 0.001)
    }

    static func languageAwareCostEstimate() {
        var job = QueueJob(
            sourcePath: "/tmp/meeting.mp4", sourceLanguage: "ja-JP",
            translationLanguage: "zh-CN", summarize: true
        )
        job.durationSeconds = 600
        let value = CostEstimator.estimate(job, settings: UserSettings())
        precondition(abs(value.scribe - 0.033) < 0.00001)
        precondition(value.translate > 0 && value.summarize > 0)
        job.reuseExistingTranscript = true
        job.reuseExistingTranslation = true
        job.reuseExistingSummary = true
        let reused = CostEstimator.estimate(job, settings: UserSettings())
        precondition(reused.total == 0)
    }

    static func summaryNormalizationRemovesDuplicateSections() throws {
        let input = """
        # Recap
        Opening recap remains.

        # Summary

        ## Project Status
        Alpha work is moving ahead with the launch.

        ## Project Status
        Alpha work is moving ahead with the launch and the final review is scheduled.

        ## Decisions
        The team approved the release.

        # Action Items
        - Prepare release notes.
        """
        let normalized = ZoomAIClient.normalizeSummaryText(input)
        let projectHeadings = normalized.components(separatedBy: "## Project Status").count - 1
        try expect(projectHeadings == 1, "Duplicate summary headings removed")
        try expect(normalized.contains("final review is scheduled"), "Longer duplicate retained")
        try expect(normalized.contains("## Decisions"), "Distinct summary section retained")
        try expect(normalized.contains("# Recap"), "Recap retained")
        try expect(normalized.contains("# Action Items"), "Action items retained")
    }

    static func partialOutputsResumeOnlyMissingWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var job = QueueJob(
            sourcePath: directory.appendingPathComponent("meeting.mp4").path,
            translationLanguage: "zh-CN",
            summarize: true
        )
        let urls = MediaPipeline.sidecarURLs(
            for: URL(fileURLWithPath: job.sourcePath),
            translationLanguage: job.translationLanguage
        )
        try "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\nHello\n"
            .write(to: urls.originalVTT, atomically: true, encoding: .utf8)
        job = MediaPipeline.applyExistingOutputs(to: job)
        try expect(job.state == .queued, "Partial outputs stay queued")
        try expect(job.reuseExistingTranscript == true, "Original captions marked reusable")
        try expect(job.reuseExistingTranslation != true, "Missing translation not reused")

        try "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\nNi hao\n"
            .write(to: urls.translatedVTT, atomically: true, encoding: .utf8)
        try "# Summary\n\n## Topic\nDone."
            .write(to: urls.summary, atomically: true, encoding: .utf8)
        job = MediaPipeline.applyExistingOutputs(to: job)
        try expect(job.state == .ready, "Complete sidecars restore ready state")
        try expect(
            job.reuseExistingTranslation == true && job.reuseExistingSummary == true,
            "Translation and summary marked reusable"
        )
    }

    static func processingTimeEstimatesAndCalibration() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var job = QueueJob(
            sourcePath: "/tmp/meeting.mp4",
            translationLanguage: "zh-CN",
            summarize: true
        )
        job.durationSeconds = 120
        job.translationInputCharacters = 1_000
        job.translationOutputCharacters = 1_000
        job.summaryInputCharacters = 1_000
        job.startedAt = started
        job.completedAt = started.addingTimeInterval(20)
        job.events = [
            JobEvent(at: started, stage: .preparing, message: "Prepare"),
            JobEvent(at: started.addingTimeInterval(2), stage: .transcribing, message: "Scribe"),
            JobEvent(at: started.addingTimeInterval(12), stage: .translating, message: "Translate"),
            JobEvent(at: started.addingTimeInterval(15), stage: .summarizing, message: "Summary"),
            JobEvent(at: started.addingTimeInterval(20), stage: .ready, message: "Ready")
        ]
        let actual = TimeEstimator.actual(for: job)
        try expect(actual.scribe == 12, "Measured Scribe time")
        try expect(actual.translate == 3, "Measured Translator time")
        try expect(actual.summarize == 5, "Measured Summarizer time")

        let calibration = JobTimeCalibration.learn(from: [job])
        try expect(calibration.scribe.sampleCount == 1, "Scribe calibration sample")
        let comparison = TimeEstimator.compare(
            job, settings: UserSettings(), calibration: calibration
        )
        try expect(comparison.estimate.total != nil, "Calibrated total estimate")
        try expect(TimeEstimator.format(65) == "1m 05s", "Time formatting")
    }

    static func playbackCompatibilityArgumentsPreserveVideo() throws {
        let arguments = PlaybackResolver.streamCopyArguments(
            input: URL(fileURLWithPath: "/tmp/input.mkv"),
            output: URL(fileURLWithPath: "/tmp/output.mov")
        )
        try expect(arguments.contains("0:v:0?"), "Playback keeps optional video")
        try expect(arguments.contains("pcm_s16le"), "Playback normalizes audio")
        try expect(arguments.suffix(2) == ["mov", "/tmp/output.mov"], "Playback MOV output")
    }

    static func interruptedQueueStateIsRecovered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStore(paths: try AppPaths(root: root))
        var job = QueueJob(sourcePath: "/tmp/meeting.mp4")
        job.report(.transcribing, progress: 0.5, "Working")
        try store.saveQueue([job])
        guard let recovered = try store.loadQueue().first else {
            throw CheckFailure("Queue recovery")
        }
        try expect(recovered.state == .queued && recovered.progress == 0, "Queue recovery")
    }

    static func processCancellationTerminatesChild() async throws {
        let start = Date()
        let task = Task {
            try await ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 10"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure("Process cancellation result")
        } catch is CancellationError {
            try expect(Date().timeIntervalSince(start) < 3, "Process cancellation latency")
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        if !condition() { throw CheckFailure(name) }
    }

    static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw CheckFailure(name) }
        return value
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestBody = request.httpBody ?? request.httpBodyStream.map(read) ?? Data()
        Self.lock.withLock { Self.body = requestBody }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let payload = Data(#"{"result":{"text_display":"Hello","segments":[{"start":0,"end":1,"text":"Hello"}]}}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func lastBody() throws -> Data {
        let value = lock.withLock { body }
        if value.isEmpty { throw CheckFailure("Captured HTTP body") }
        return value
    }

    private func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

struct CheckFailure: LocalizedError {
    let name: String
    init(_ name: String) { self.name = name }
    var errorDescription: String? { "Check failed: \(name)" }
}
