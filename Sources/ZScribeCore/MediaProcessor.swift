import Foundation

public struct AudioProfile: Sendable {
    public var fileExtension: String
    public var mimeType: String
    public var codec: String
    public var streamCopy: Bool
    public var outputBitRate: Int64?
}

public enum MediaProcessor {
    public static let uploadTargetBytes: Int64 = 80_000_000

    public static func probe(url: URL, settings: UserSettings) async throws -> MediaProbe {
        let output = try await ProcessRunner.run(settings.ffprobePath, arguments: [
            "-v", "error",
            "-show_entries", "format=duration:stream=index,codec_type,codec_name,sample_rate,channels,bit_rate,duration,disposition",
            "-of", "json", url.path
        ])
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }

        let streams = root["streams"] as? [[String: Any]] ?? []
        let audioCandidates = streams.enumerated().filter {
            ($0.element["codec_type"] as? String) == "audio" &&
            !string($0.element["codec_name"]).isEmpty
        }
        let audio = audioCandidates.sorted {
            isDefault($0.element) && !isDefault($1.element)
        }.first
        let format = root["format"] as? [String: Any] ?? [:]
        let durations = [positiveDouble(format["duration"]), positiveDouble(audio?.element["duration"])]
            + streams.map { positiveDouble($0["duration"]) }
        guard let duration = durations.compactMap({ $0 }).max(), duration > 0 else {
            throw NSError(domain: "ZScribe.Media", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "FFprobe did not return a positive media duration."])
        }

        return MediaProbe(
            duration: duration,
            audioCodec: string(audio?.element["codec_name"]).lowercased(),
            sampleRate: int(audio?.element["sample_rate"]),
            channels: int(audio?.element["channels"]),
            bitRate: int64(audio?.element["bit_rate"]),
            hasVideo: streams.contains { string($0["codec_type"]) == "video" },
            audioStreamIndex: int(audio?.element["index"], fallback: audio?.offset ?? -1)
        )
    }

    public static func extract(
        source: URL,
        workDirectory: URL,
        probe: MediaProbe,
        settings: UserSettings,
        progress: @escaping (Double) async -> Void
    ) async throws -> [PreparedAudioPart] {
        guard !probe.audioCodec.isEmpty else {
            throw NSError(domain: "ZScribe.Media", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The selected file has no audio stream."])
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let profile = normalizeProfile(probe)
        let requested = Double(min(max(settings.segmentMinutes, 1), 30) * 60)
        let segmentDuration = segmentDuration(probe: probe, profile: profile, requested: requested)
        let count = max(1, Int(ceil(probe.duration / segmentDuration)))
        var parts: [PreparedAudioPart] = []

        for index in 0..<count {
            try Task.checkCancellation()
            let start = Double(index) * segmentDuration
            let duration = min(segmentDuration, probe.duration - start)
            guard duration > 0 else { break }
            let output = workDirectory.appendingPathComponent(
                String(format: "audio-%03d.%@", index + 1, profile.fileExtension)
            )
            var arguments = [
                "-hide_banner", "-nostdin", "-y", "-i", source.path,
                "-ss", decimal(start), "-t", decimal(duration),
                "-map", probe.audioStreamIndex >= 0 ? "0:\(probe.audioStreamIndex)" : "0:a:0",
                "-vn", "-c:a", profile.codec
            ]
            if !profile.streamCopy {
                arguments += ["-ac", "\(min(max(probe.channels, 1), 2))"]
                if let bitRate = profile.outputBitRate { arguments += ["-b:a", "\(bitRate / 1000)k"] }
            }
            arguments.append(output.path)
            _ = try await ProcessRunner.run(settings.ffmpegPath, arguments: arguments)
            let values = try output.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0 else {
                throw NSError(domain: "ZScribe.Media", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "FFmpeg produced an empty audio segment."])
            }
            guard size < 100 * 1024 * 1024 else {
                throw NSError(domain: "ZScribe.Media", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "An audio segment exceeded Zoom's 100 MB limit."])
            }
            parts.append(PreparedAudioPart(
                index: index, url: output, timelineStart: start,
                duration: duration, mimeType: profile.mimeType
            ))
            await progress(Double(index + 1) / Double(count))
        }
        return parts
    }

    public static func profile(for codec: String) -> AudioProfile {
        switch codec.lowercased() {
        case "aac", "alac": .init(fileExtension: "m4a", mimeType: "audio/mp4",
                                  codec: "copy", streamCopy: true)
        case "mp3": .init(fileExtension: "mp3", mimeType: "audio/mpeg",
                          codec: "copy", streamCopy: true)
        default: compatibilityProfile
        }
    }

    public static func normalizeProfile(_ probe: MediaProbe) -> AudioProfile {
        let selected = profile(for: probe.audioCodec)
        if selected.streamCopy && (probe.channels > 2 || (probe.bitRate ?? 0) <= 0) {
            return compatibilityProfile
        }
        return selected
    }

    public static func segmentDuration(
        probe: MediaProbe, profile: AudioProfile, requested: TimeInterval
    ) -> TimeInterval {
        let bytesPerSecond: Int64
        if let rate = profile.outputBitRate, rate > 0 {
            bytesPerSecond = max(1, rate / 8)
        } else if profile.streamCopy, let rate = probe.bitRate, rate > 0 {
            bytesPerSecond = max(1, rate / 8)
        } else {
            bytesPerSecond = Int64(max(probe.sampleRate, 48_000) * min(max(probe.channels, 1), 2) * 2)
        }
        return min(requested, Double(max(1, uploadTargetBytes / bytesPerSecond)))
    }

    private static let compatibilityProfile = AudioProfile(
        fileExtension: "mp3", mimeType: "audio/mpeg",
        codec: "libmp3lame", streamCopy: false, outputBitRate: 128_000
    )

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value { return String(describing: value) }
        return ""
    }
    private static func int(_ value: Any?, fallback: Int = 0) -> Int {
        Int(string(value)) ?? fallback
    }
    private static func int64(_ value: Any?) -> Int64? { Int64(string(value)) }
    private static func positiveDouble(_ value: Any?) -> Double? {
        guard let number = Double(string(value)), number.isFinite, number > 0 else { return nil }
        return number
    }
    private static func isDefault(_ stream: [String: Any]) -> Bool {
        let disposition = stream["disposition"] as? [String: Any]
        return int(disposition?["default"]) == 1
    }
}
