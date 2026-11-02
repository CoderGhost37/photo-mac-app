import Foundation

public enum ModelChecksums {
    /// `sha256sum` lines: 64 hex digits, whitespace, then a relative path. `#` starts a comment.
    public static func parse(_ manifest: String) -> [String: String] {
        var files: [String: String] = [:]
        for line in manifest.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit), isSafe(path) else { continue }
            files[path] = hash
        }
        return files
    }

    /// Paths whose bytes do not match. Missing paths are included.
    public static func failures(expected: [String: String], actual: [String: String]) -> [String] {
        expected.keys.sorted().compactMap { path in
            actual[path] == expected[path] ? nil : path
        }
    }

    public static func hashTree(directory: URL, excluding: Set<String> = [ClipModel.checksumName]) throws -> [String: String] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return [:]
        }
        let hasher = SHA256FileHasher()
        var hashes: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if url.lastPathComponent.hasPrefix(".") { continue }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = String(full.dropFirst(rootPath.count + 1))
            if excluding.contains(relative) || !isSafe(relative) { continue }
            hashes[relative] = try hasher.hash(ofFileAt: url).lowercased()
        }
        return hashes
    }

    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("..") && !path.contains("\\")
    }
}
