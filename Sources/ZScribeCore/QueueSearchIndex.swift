import Foundation

public actor QueueSearchIndex {
    private static let maxConcurrentReads = 4
    private static let maxCachedCharacters = 16 * 1024 * 1024

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let modifiedAt: Date
    }

    private struct CachedFile: Sendable {
        let stamp: FileStamp
        let text: String
    }

    private struct CachedFileKey: Sendable {
        let path: String
        let stamp: FileStamp
    }

    private var fileCache: [String: CachedFile] = [:]
    private var cacheOrder: [CachedFileKey] = []
    private var cachedCharacters = 0

    public init() {}

    public func findMatches(in jobs: [QueueJob], query rawQuery: String) async -> Set<UUID> {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Set(jobs.map(\.id)) }

        var matches = Set<UUID>()
        for start in stride(from: 0, to: jobs.count, by: Self.maxConcurrentReads) {
            if Task.isCancelled { return matches }
            let batch = Array(jobs[start..<min(start + Self.maxConcurrentReads, jobs.count)])
            let batchMatches = await withTaskGroup(of: UUID?.self) { group in
                for job in batch {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        return await self.matches(job, query: query) ? job.id : nil
                    }
                }
                var values: [UUID] = []
                for await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            matches.formUnion(batchMatches)
        }
        return matches
    }

    private func matches(_ job: QueueJob, query: String) async -> Bool {
        if contains(job.displayName, query) { return true }
        for path in artifactPaths(for: job) {
            if Task.isCancelled { return false }
            if let text = await readText(at: path), contains(text, query) { return true }
        }
        return false
    }

    private func readText(at path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
        ]),
        values.isRegularFile == true,
        let size = values.fileSize,
        size > 0,
        let modifiedAt = values.contentModificationDate else {
            return nil
        }

        let stamp = FileStamp(size: size, modifiedAt: modifiedAt)
        if let cached = fileCache[path], cached.stamp == stamp {
            return cached.text
        }

        let text = try? await Task.detached(priority: .utility) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
        guard let text else { return nil }
        cache(path: path, stamp: stamp, text: text)
        return text
    }

    private func cache(path: String, stamp: FileStamp, text: String) {
        if let previous = fileCache[path] {
            cachedCharacters -= previous.text.count
        }
        fileCache[path] = CachedFile(stamp: stamp, text: text)
        cacheOrder.append(CachedFileKey(path: path, stamp: stamp))
        cachedCharacters += text.count

        while cachedCharacters > Self.maxCachedCharacters, !cacheOrder.isEmpty {
            let oldest = cacheOrder.removeFirst()
            guard let cached = fileCache[oldest.path], cached.stamp == oldest.stamp else {
                continue
            }
            fileCache.removeValue(forKey: oldest.path)
            cachedCharacters -= cached.text.count
        }
    }

    private func artifactPaths(for job: QueueJob) -> [String] {
        var paths = Set<String>()
        [job.originalVttPath, job.translatedVttPath, job.transcriptJsonPath, job.summaryPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .forEach { paths.insert($0) }

        let source = URL(fileURLWithPath: job.sourcePath)
        let sidecars = MediaPipeline.sidecarURLs(
            for: source, translationLanguage: job.translationLanguage
        )
        paths.insert(sidecars.originalVTT.path)
        paths.insert(sidecars.transcriptJSON.path)
        paths.insert(sidecars.summary.path)
        if !job.translationLanguage.isEmpty {
            paths.insert(sidecars.translatedVTT.path)
        }

        let directory = source.deletingLastPathComponent()
        let prefix = source.deletingPathExtension().lastPathComponent + ".translated-"
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where
                file.lastPathComponent.hasPrefix(prefix) &&
                file.pathExtension.caseInsensitiveCompare("vtt") == .orderedSame {
                paths.insert(file.path)
            }
        }
        return Array(paths)
    }

    private func contains(_ text: String, _ query: String) -> Bool {
        text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) != nil
    }
}
