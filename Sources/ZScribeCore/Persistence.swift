import Foundation
import Security

public struct AppPaths: Sendable {
    public let root: URL
    public let queue: URL
    public let settings: URL
    public let work: URL

    public init(root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Z Scribe", isDirectory: true)
        self.root = base
        queue = base.appendingPathComponent("queue.json")
        settings = base.appendingPathComponent("settings.json")
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

public final class KeychainCredentialStore {
    private let service = "com.tanchunsiong.ZScribeMac.ZoomBuildCredentials"
    private let account = "ZoomBuild"

    public init() {}

    public func load() throws -> APICredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw keychainError(status)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        guard let key = object?["apiKey"], let secret = object?["apiSecret"] else { return nil }
        return APICredentials(apiKey: key, apiSecret: secret)
    }

    public func save(_ credentials: APICredentials) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "apiKey": credentials.apiKey,
            "apiSecret": credentials.apiSecret
        ])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if update != errSecSuccess {
            throw keychainError(update)
        }
    }

    public func clear() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey:
                SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"]
        )
    }
}
