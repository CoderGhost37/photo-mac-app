import Foundation

/// Resolves the folder macOS uses for screenshots.
///
/// System Settings writes this to the `location` key of `com.apple.screencapture`.
/// When the key is missing, screenshots land on the Desktop.
public enum ScreenshotLocation {
    public static func resolve(preferenceValue: String?, home: URL) -> URL {
        let trimmed = preferenceValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path: String
        if trimmed.isEmpty {
            path = home.appendingPathComponent("Desktop", isDirectory: true).path
        } else if trimmed == "~" {
            path = home.path
        } else if trimmed.hasPrefix("~/") {
            path = home.path + trimmed.dropFirst(1)
        } else {
            path = trimmed
        }
        return SourceCatalog.normalizedDirectory(URL(fileURLWithPath: path, isDirectory: true))
    }

    #if os(macOS)
    public static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        resolve(preferenceValue: readPreference(), home: home)
    }

    /// Reads `defaults` domain `com.apple.screencapture`, key `location`.
    public static func readPreference() -> String? {
        let value = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        )
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif
}
