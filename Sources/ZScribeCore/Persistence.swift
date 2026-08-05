import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let queue: URL
    public let settings: URL
    public let credentials: URL
    public let work: URL

    public init(root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Z Scribe", isDirectory: true)
        self.root = base
        queue = base.appendingPathComponent("queue.json")
        settings = base.appendingPathComponent("settings.json")
        credentials = base.appendingPathComponent("credentials.json")
        work = base.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
}

public final class JSONStore {
    private let paths: AppPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: AppPaths) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadQueue() throws -> [QueueJob] {
        guard FileManager.default.fileExists(atPath: paths.queue.path) else { return [] }
        let jobs = try decoder.decode([QueueJob].self, from: Data(contentsOf: paths.queue))
        return jobs.map { job in
            var recovered = job
            if recovered.state.isProcessing {
                recovered.report(.queued, progress: 0, "Recovered after the previous app session ended")
            }
            return recovered
        }
    }

    public func saveQueue(_ jobs: [QueueJob]) throws {
        try atomicWrite(encoder.encode(jobs), to: paths.queue)
    }

    public func loadSettings() throws -> UserSettings {
        guard FileManager.default.fileExists(atPath: paths.settings.path) else {
            return UserSettings()
        }
        var settings = try decoder.decode(UserSettings.self, from: Data(contentsOf: paths.settings))
        settings.clamp()
        return settings
    }

    public func saveSettings(_ value: UserSettings) throws {
        var settings = value
        settings.clamp()
        try atomicWrite(encoder.encode(settings), to: paths.settings)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

public final class FileCredentialStore {
    private let url: URL

    public init(paths: AppPaths) {
        url = paths.credentials
    }

    public func load() throws -> APICredentials? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: String]
        guard let key = object?["apiKey"], let secret = object?["apiSecret"] else { return nil }
        return APICredentials(apiKey: key, apiSecret: secret)
    }

    public func save(_ credentials: APICredentials) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "apiKey": credentials.apiKey,
            "apiSecret": credentials.apiSecret
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
