import AVFoundation
import CryptoKit
import Foundation

public final class PlaybackResolver {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func resolve(_ source: URL, settings: UserSettings) async throws -> URL {
        let asset = AVURLAsset(url: source)
        if (try? await asset.load(.isPlayable)) == true {
            return source
        }

        let values = try source.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey
        ])
        let identity = [
            source.standardizedFileURL.path,
            String(values.fileSize ?? 0),
            String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = paths.work.appendingPathComponent("playback", isDirectory: true)
        let output = directory.appendingPathComponent("\(digest).mov")
        if Self.hasContent(output) { return output }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("\(digest).\(UUID().uuidString).tmp.mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            _ = try await ProcessRunner.run(
                settings.ffmpegPath,
                arguments: Self.streamCopyArguments(input: source, output: temporary)
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            _ = try await ProcessRunner.run(settings.ffmpegPath, arguments: [
                "-hide_banner", "-nostdin", "-y",
                "-i", source.path,
                "-map", "0:v:0?",
                "-map", "0:a:0?",
                "-map_metadata", "0",
                "-c:v", "h264_videotoolbox",
                "-b:v", "8M",
                "-c:a", "aac",
                "-b:a", "192k",
                "-ac", "2",
                "-movflags", "+faststart",
                "-f", "mov",
                temporary.path
            ])
        }
        guard Self.hasContent(temporary) else {
            throw NSError(
                domain: "ZScribe.Playback",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "FFmpeg produced an empty playback compatibility file."]
            )
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }

    public static func streamCopyArguments(input: URL, output: URL) -> [String] {
        [
            "-hide_banner", "-nostdin", "-y",
            "-i", input.path,
            "-map", "0:v:0?",
            "-map", "0:a:0?",
            "-map_metadata", "0",
            "-c:v", "copy",
            "-c:a", "pcm_s16le",
            "-ac", "2",
            "-f", "mov",
            output.path
        ]
    }

    private static func hasContent(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } == true
    }
}
