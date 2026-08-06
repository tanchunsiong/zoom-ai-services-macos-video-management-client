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
        let bodyURL = part.url.deletingLastPathComponent().appendingPathComponent(
            "scribe-\(part.index)-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Self.writeScribeBody(
            audioURL: part.url,
            mimeType: part.mimeType,
            language: language,
            to: bodyURL
        )
        let root = try await sendFile(
            service: "Zoom Scribe",
            url: scribeURL,
            bodyURL: bodyURL,
            credentials: credentials
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

    public func translate(
        _ text: String, source: String, target: String, credentials: APICredentials
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var translated = trimmed
        for step in TranslationRoute.build(source: source, target: target) {
            let result = try await translateText(
                translated,
                source: step.0,
                target: step.1,
                credentials: credentials
            )
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "ZScribe.Live.Translation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Zoom Translator returned an empty translation."]
                )
            }
            translated = result.text
        }
        return translated
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
            result.text = Self.normalizeSummaryText(result.text)
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
        final.text = Self.normalizeSummaryText(final.text)
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

    private func sendFile(
        service: String,
        url: URL,
        bodyURL: URL,
        credentials: APICredentials
    ) async throws -> [String: Any] {
        let retryable = [429, 502, 503, 504]
        let defaultDelays: [TimeInterval] = [2, 5]
        for attempt in 0...2 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(
                "Bearer \(try ZoomJWT.create(credentials: credentials))",
                forHTTPHeaderField: "Authorization"
            )
            do {
                let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
                let http = response as! HTTPURLResponse
                if (200..<300).contains(http.statusCode) {
                    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                }
                let body = String(decoding: data, as: UTF8.self)
                if retryable.contains(http.statusCode), attempt < 2 {
                    let headerDelay = http.value(
                        forHTTPHeaderField: "Retry-After"
                    ).flatMap(TimeInterval.init)
                    try await Task.sleep(for: .seconds(
                        min(max(headerDelay ?? retryDelay(from: data) ?? defaultDelays[attempt], 1), 300)
                    ))
                    continue
                }
                throw ZoomAPIError(
                    service: service,
                    statusCode: http.statusCode,
                    responseBody: body
                )
            } catch let error as ZoomAPIError {
                throw error
            } catch where attempt < 2 {
                try await Task.sleep(for: .seconds(defaultDelays[attempt]))
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    public static func writeScribeBody(
        audioURL: URL,
        mimeType: String,
        language: String,
        to outputURL: URL
    ) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let input = try FileHandle(forReadingFrom: audioURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: Data(#"{"file":"data:\#(mimeType);base64,"#.utf8))
        let chunkSize = 48 * 1024
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk.base64EncodedData())
        }
        let config = try JSONSerialization.data(withJSONObject: [
            "language": language,
            "channel_separation": false
        ], options: [.sortedKeys])
        try output.write(contentsOf: Data(#"","config":"#.utf8))
        try output.write(contentsOf: config)
        try output.write(contentsOf: Data("}".utf8))
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

    public static func normalizeSummaryText(_ text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard let summaryStart = lines.firstIndex(where: {
            matches($0, pattern: #"^\s*#\s+Summary\s*$"#)
        }) else {
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let summaryEnd = lines[(summaryStart + 1)...].firstIndex(where: {
            matches($0, pattern: #"^\s*#\s+\S"#)
        }) ?? lines.endIndex
        let sectionStarts = (summaryStart + 1..<summaryEnd).filter {
            matches(lines[$0], pattern: #"^\s*#{2,}\s+\S"#)
        }
        guard sectionStarts.count >= 2 else {
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var sections: [(heading: String, body: String)] = []
        for (position, start) in sectionStarts.enumerated() {
            let end = position + 1 < sectionStarts.count
                ? sectionStarts[position + 1] : summaryEnd
            let heading = lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = lines[(start + 1)..<end].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if let duplicate = sections.firstIndex(where: {
                normalizeHeading($0.heading) == normalizeHeading(heading) ||
                    wordSimilarity($0.body, body) >= 0.70
            }) {
                if body.count > sections[duplicate].body.count {
                    sections[duplicate] = (heading, body)
                }
            } else {
                sections.append((heading, body))
            }
        }
        guard !sections.isEmpty else {
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var rebuilt = Array(lines.prefix(summaryStart + 1))
        rebuilt.append("")
        for section in sections {
            rebuilt += [section.heading, section.body, ""]
        }
        rebuilt += lines.suffix(from: summaryEnd)
        return rebuilt.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func normalizeHeading(_ heading: String) -> String {
        heading.lowercased()
            .replacingOccurrences(
                of: #"[^\p{L}\p{N}]+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordSimilarity(_ first: String, _ second: String) -> Double {
        let firstWords = words(first)
        let secondWords = words(second)
        guard !firstWords.isEmpty, !secondWords.isEmpty else { return 0 }
        let union = firstWords.union(secondWords)
        return union.isEmpty
            ? 0
            : Double(firstWords.intersection(secondWords).count) / Double(union.count)
    }

    private static func words(_ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]{3,}"#) else {
            return []
        }
        let lower = text.lowercased()
        let ns = lower as NSString
        return Set(regex.matches(
            in: lower,
            range: NSRange(location: 0, length: ns.length)
        ).map { ns.substring(with: $0.range) })
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
