import Foundation

public struct CaptureToolMatch: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var path: String

    public init(id: String, displayName: String, path: String) {
        self.id = id
        self.displayName = displayName
        self.path = path
    }
}

/// Reads a screenshot app's preferences and turns a save folder into a library source.
/// The preference dictionaries are passed in so this can be tested without the apps installed.
public enum CaptureToolPreferences {
    public static let cleanShotID = "tool.cleanshot"
    public static let shottrID = "tool.shottr"

    /// CleanShot X writes its export folder to `exportPath`. The other keys are older or alternate builds.
    public static let cleanShotKeys = ["exportPath", "savePath", "screenshotPath", "defaultSavePath", "defaultFolder"]
    /// Shottr's folder key is not published. These names, then any key that looks like a path, are checked.
    public static let shottrKeys = [
        "defaultFolder", "saveFolder", "savePath", "screenshotsFolder", "exportPath", "folderPath", "saveDirectory"
    ]

    public static func directory(in preferences: [String: Any], keys: [String], home: URL) -> String? {
        for key in keys {
            if let path = pathString(preferences[key], home: home) {
                return path
            }
        }
        let hints = ["folder", "path", "directory", "export", "save"]
        let extra = preferences.keys.filter { key in
            if keys.contains(key) { return false }
            let lower = key.lowercased()
            return hints.contains { lower.contains($0) }
        }.sorted()
        for key in extra {
            if let path = pathString(preferences[key], home: home) {
                return path
            }
        }
        return nil
    }

    /// Drops a tool whose folder is already indexed, so the same files are not listed twice.
    public static func offering(_ matches: [CaptureToolMatch], existingRoots: [String]) -> [CaptureToolMatch] {
        let roots = Set(existingRoots.map(normalize))
        var seen = Set<String>()
        var kept: [CaptureToolMatch] = []
        for match in matches {
            let path = normalize(match.path)
            if path.isEmpty || path == "/" || roots.contains(path) || seen.contains(path) { continue }
            seen.insert(path)
            kept.append(CaptureToolMatch(id: match.id, displayName: match.displayName, path: path))
        }
        return kept
    }

    public static func source(for match: CaptureToolMatch) -> Source {
        Source(
            id: match.id,
            kind: .captureTool,
            displayName: match.displayName,
            rootPath: normalize(match.path),
            bookmarkData: nil,
            enabled: true,
            lastScanAt: nil
        )
    }

    private static func pathString(_ value: Any?, home: URL) -> String? {
        let raw: String?
        if let string = value as? String {
            raw = string
        } else if let url = value as? URL {
            raw = url.isFileURL ? url.path : nil
        } else {
            raw = nil
        }
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("file:"), let url = URL(string: text), url.isFileURL {
            text = url.path
        }
        let path = ScreenshotLocation.resolve(preferenceValue: text, home: home).path
        if path.isEmpty || path == "/" { return nil }
        return path
    }

    private static func normalize(_ path: String) -> String {
        SourceCatalog.normalizedDirectory(URL(fileURLWithPath: path, isDirectory: true)).path
    }
}
