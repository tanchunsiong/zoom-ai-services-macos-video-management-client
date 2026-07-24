import Foundation

public struct TranslationResult: Sendable {
    public var cues: [TranscriptCue]
    public var inputCharacters: Int
    public var outputCharacters: Int
}

public struct SummaryResult: Sendable {
    public var text: String
    public var inputCharacters: Int
    public var outputCharacters: Int
    public var requestID: String?
    public var model: String?
}

public struct ZoomAPIError: LocalizedError {
    public let service: String
    public let statusCode: Int
    public let responseBody: String
    public var errorDescription: String? {
        "\(service) returned HTTP \(statusCode). \(responseBody.prefix(800))"
    }
}

public final class ZoomAIClient {
    private let session: URLSession
    private let scribeURL = URL(string: "https://api.zoom.us/v2/aiservices/scribe/transcribe")!
    private let translateURL = URL(string: "https://api.zoom.us/v2/aiservices/translator/translate")!
    private let summarizeURL = URL(string: "https://api.zoom.us/v2/aiservices/summarizer/summarize")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func transcribe(
        part: PreparedAudioPart, language: String, credentials: APICredentials
    ) async throws -> TranscriptDocument {
        let audio = try Data(contentsOf: part.url)
        let payload: [String: Any] = [
            "file": "data:\(part.mimeType);base64,\(audio.base64EncodedString())",
            "config": [
                "language": language,
                "channel_separation": false
            ]
        ]
        let root = try await send(
            service: "Zoom Scribe", url: scribeURL, payload: payload, credentials: credentials
        )
        let result = root["result"] as? [String: Any] ?? root
        let text = firstString(result, ["text_display", "text_lexical", "text"])
        let segments = result["segments"] as? [[String: Any]] ?? []
        var cues = segments.compactMap { segment -> TranscriptCue? in
            let body = firstString(segment, ["text_display", "text_lexical", "text"])
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = firstDouble(segment, ["start", "start_time", "start_sec"])
            var end = firstDouble(segment, ["end", "end_time", "end_sec"])
            if end <= start { end = start + 2 }
            return TranscriptCue(index: 0, start: start, end: end, text: body)
        }
        if cues.isEmpty && !text.isEmpty {
            cues = [TranscriptCue(index: 1, start: 0, end: 2, text: text)]
        } else {
            cues = cues.enumerated().map {
                TranscriptCue(index: $0.offset + 1, start: $0.element.start,
                              end: $0.element.end, text: $0.element.text)
            }
        }
        return TranscriptDocument(
            language: language, cues: cues, text: text,
            requestID: root["request_id"] as? String,
            model: root["model"] as? String
        )
    }

    public func translateCues(
        _ cues: [TranscriptCue], source: String, target: String, credentials: APICredentials
    ) async throws -> TranslationResult {
        var translated: [Int: String] = [:]
        var inputCharacters = 0
        var outputCharacters = 0
        for batch in cueBatches(cues, maximumLength: 3_600) {
            let body = batch.map {
                String(format: "[[[ZT_CUE_%06d]]] %@", $0.index, flatten($0.text))
            }.joined(separator: "\n")
            let result = try await translateText(
                body, source: source, target: target, credentials: credentials
            )
            inputCharacters += result.input
            outputCharacters += result.output
            for match in markerMatches(result.text) {
                translated[match.index] = match.text
            }
        }

        for cue in cues where translated[cue.index] == nil {
            let result = try await translateText(
                cue.text, source: source, target: target, credentials: credentials
            )
            inputCharacters += result.input
            outputCharacters += result.output
            translated[cue.index] = result.text
        }
        return TranslationResult(
            cues: cues.map {
                TranscriptCue(index: $0.index, start: $0.start, end: $0.end,
                              text: translated[$0.index] ?? $0.text)
            },
            inputCharacters: inputCharacters,
            outputCharacters: outputCharacters
        )
    }

    public func summarize(
        _ text: String, language: String, credentials: APICredentials
    ) async throws -> SummaryResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SummaryResult(text: "No spoken content was available to summarize.",
                                 inputCharacters: 0, outputCharacters: 0)
        }
        let chunks = splitUTF8(text, maximumBytes: 80 * 1024)
        if chunks.count == 1 {
            var result = try await summarizeText(
                chunks[0], language: language, task: "full_summary", credentials: credentials
            )
            result.text = normalizeSummary(result.text)
            return result
        }

        var input = 0
        var output = 0
        var combined = ""
        for chunk in chunks {
            let result = try await summarizeText(
                chunk, language: language, task: "summary", credentials: credentials
            )
            input += result.inputCharacters
            output += result.outputCharacters
            combined += result.text + "\n\n"
        }
        while combined.utf8.count > 80 * 1024 {
            var next = ""
            for chunk in splitUTF8(combined, maximumBytes: 80 * 1024) {
                let result = try await summarizeText(
                    chunk, language: language, task: "summary", credentials: credentials
                )
                input += result.inputCharacters
                output += result.outputCharacters
                next += result.text + "\n\n"
            }
            guard next.count < combined.count else {
                throw NSError(domain: "ZScribe.Summary", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "The transcript is too large for Zoom Summarizer Fast mode."])
            }
            combined = next
        }
        var final = try await summarizeText(
            combined, language: language, task: "full_summary", credentials: credentials
        )
        final.text = normalizeSummary(final.text)
        final.inputCharacters += input
        final.outputCharacters += output
        return final
    }

    public func validateLocally(_ credentials: APICredentials) throws {
        let token = try ZoomJWT.create(credentials: credentials)
        guard token.filter({ $0 == "." }).count == 2 else {
            throw NSError(domain: "ZScribe.Credentials", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create a Zoom Build token."])
        }
    }

    private func translateText(
        _ text: String, source: String, target: String, credentials: APICredentials
    ) async throws -> (text: String, input: Int, output: Int) {
        let root = try await send(
            service: "Zoom Translator",
            url: translateURL,
            payload: [
                "text": text,
                "config": ["source_language": source, "target_languages": [target]],
                "reference_id": "macos-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            ],
            credentials: credentials
        )
        let result = root["result"] as? [String: Any]
        let translations = result?["translations"] as? [String: Any]
        let translated = translations?[target] as? String ?? ""
        let usage = root["usage"] as? [String: Any]
        return (
            translated,
            int(usage?["input_units"], fallback: text.count),
            int(usage?["output_units"], fallback: translated.count)
        )
    }

    private func summarizeText(
        _ text: String, language: String, task: String, credentials: APICredentials
    ) async throws -> SummaryResult {
        let root = try await send(
            service: "Zoom Summarizer",
            url: summarizeURL,
            payload: [
                "input": ["text": text],
                "config": [
                    "summary_type": "CONVERSATION",
                    "task": task,
                    "language": language,
                    "output_format": "text"
                ]
            ],
            credentials: credentials
        )
        let result = root["result"] as? [String: Any] ?? [:]
        let keys = task == "full_summary"
            ? ["full_summary", "summary_text", "text", "recap"]
            : ["summary_text", "text", "full_summary", "recap"]
        let summary = firstString(result, keys)
        let usage = root["usage"] as? [String: Any]
        return SummaryResult(
            text: summary,
            inputCharacters: int(usage?["input_units"], fallback: text.count),
            outputCharacters: int(usage?["output_units"], fallback: summary.count),
            requestID: root["request_id"] as? String,
            model: root["model"] as? String
        )
    }

    private func send(
        service: String, url: URL, payload: [String: Any], credentials: APICredentials
    ) async throws -> [String: Any] {
        let retryable = [429, 502, 503, 504]
        let defaultDelays: [TimeInterval] = [2, 5]
        for attempt in 0...2 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(try ZoomJWT.create(credentials: credentials))",
                             forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as! HTTPURLResponse
                if (200..<300).contains(http.statusCode) {
                    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                }
                let body = String(decoding: data, as: UTF8.self)
                if retryable.contains(http.statusCode), attempt < 2 {
                    let headerDelay = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    let bodyDelay = retryDelay(from: data)
                    try await Task.sleep(for: .seconds(min(max(headerDelay ?? bodyDelay ?? defaultDelays[attempt], 1), 300)))
                    continue
                }
                throw ZoomAPIError(service: service, statusCode: http.statusCode, responseBody: body)
            } catch let error as ZoomAPIError {
                throw error
            } catch where attempt < 2 {
                try await Task.sleep(for: .seconds(defaultDelays[attempt]))
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private func retryDelay(from data: Data) -> TimeInterval? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let metadata = root?["metadata"] as? [String: Any]
        return Double(String(describing: metadata?["retry_after_seconds"] ?? ""))
    }

    private func cueBatches(_ cues: [TranscriptCue], maximumLength: Int) -> [[TranscriptCue]] {
        var batches: [[TranscriptCue]] = []
        var batch: [TranscriptCue] = []
        var length = 0
        for cue in cues {
            let size = cue.text.count + 30
            if !batch.isEmpty && length + size > maximumLength {
                batches.append(batch)
                batch = []
                length = 0
            }
            batch.append(cue)
            length += size
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private func markerMatches(_ text: String) -> [(index: Int, text: String)] {
        let pattern = #"\[\[\[\s*ZT_CUE_(\d{6})\s*\]\]\]\s*([\s\S]*?)(?=\s*\[\[\[\s*ZT_CUE_\d{6}\s*\]\]\]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap {
            guard $0.numberOfRanges == 3,
                  let index = Int(nsText.substring(with: $0.range(at: 1))) else { return nil }
            return (index, nsText.substring(with: $0.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func splitUTF8(_ text: String, maximumBytes: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let count = String(character).utf8.count
            if bytes + count > maximumBytes && !current.isEmpty {
                chunks.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func normalizeSummary(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func firstString(_ object: [String: Any], _ keys: [String]) -> String {
        keys.compactMap { object[$0] as? String }.first ?? ""
    }
    private func firstDouble(_ object: [String: Any], _ keys: [String]) -> Double {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let value = object[key] as? String, let result = Double(value) { return result }
        }
        return 0
    }
    private func int(_ value: Any?, fallback: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return Int(String(describing: value ?? "")) ?? fallback
    }
}
