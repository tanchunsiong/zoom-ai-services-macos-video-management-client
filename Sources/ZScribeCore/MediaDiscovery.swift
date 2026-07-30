import Foundation

public enum MediaDiscovery {
    public static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "mpg", "mpeg",
        "mod", "3gp", "3g2", "mts", "m2ts", "ts", "flv", "vob", "asf",
        "wav", "m4a", "mp3", "wma", "aac", "flac", "ogg", "opus", "aiff", "aif"
    ]

    public static func expand(_ urls: [URL]) -> [URL] {
        var results: [URL] = []
        let manager = FileManager.default
        for url in urls where url.isFileURL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                == true
            if !isDirectory {
                if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    results.append(url)
                }
                continue
            }
            guard let enumerator = manager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let file as URL in enumerator where
                supportedExtensions.contains(file.pathExtension.lowercased()) {
                results.append(file)
            }
        }
        return results
    }
}
