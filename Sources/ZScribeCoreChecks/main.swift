import Foundation
import ZScribeCore

@main
struct CoreChecks {
    static func main() async throws {
        try webVTTRoundTrip()
        translationRoutingBridgesThroughEnglish()
        try jwtContainsExpectedClaims()
        try await scribeRequestMatchesContract()
        try await queueSearchCoversAllArtifactsAndInvalidatesCache()
        audioProfilesMatchZoomCompatibleContainers()
        segmentDurationObservesUploadTarget()
        languageAwareCostEstimate()
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

    static func segmentDurationObservesUploadTarget() {
        let probe = MediaProbe(
            duration: 7_200, audioCodec: "mp3", sampleRate: 48_000,
            channels: 2, bitRate: 1_000_000, hasVideo: false, audioStreamIndex: 0
        )
        let duration = MediaProcessor.segmentDuration(
            probe: probe, profile: MediaProcessor.profile(for: "mp3"), requested: 900
        )
        precondition(abs(duration - 640) < 0.001)
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
