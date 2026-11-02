import Foundation
import PhotoIndex

/// Finds CleanShot X and Shottr save folders from their preference files, when those files exist.
enum CaptureToolLocator {
    static func discover(home: URL) -> [CaptureToolMatch] {
        var matches: [CaptureToolMatch] = []
        let cleanShotDomains = ["pl.maketheweb.cleanshotx", "com.getcleanshot.app", "com.getcleanshot.app-setapp"]
        for domain in cleanShotDomains {
            guard let values = preferences(domain: domain, home: home, container: false),
                  let path = CaptureToolPreferences.directory(in: values, keys: CaptureToolPreferences.cleanShotKeys, home: home),
                  isDirectory(path) else { continue }
            matches.append(CaptureToolMatch(id: CaptureToolPreferences.cleanShotID, displayName: "CleanShot X", path: path))
            break
        }
        if let values = preferences(domain: "cc.ffitch.shottr", home: home, container: true),
           let path = CaptureToolPreferences.directory(in: values, keys: CaptureToolPreferences.shottrKeys, home: home),
           isDirectory(path) {
            matches.append(CaptureToolMatch(id: CaptureToolPreferences.shottrID, displayName: "Shottr", path: path))
        }
        return matches
    }

    private static func preferences(domain: String, home: URL, container: Bool) -> [String: Any]? {
        var merged: [String: Any] = [:]
        var urls = [
            home.appendingPathComponent("Library/Preferences/\(domain).plist")
        ]
        if container {
            urls.insert(
                home.appendingPathComponent("Library/Containers/\(domain)/Data/Library/Preferences/\(domain).plist"),
                at: 0
            )
        }
        for url in urls {
            guard let values = dictionary(at: url) else { continue }
            for (key, value) in values {
                merged[key] = value
            }
        }
        if let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
           !keys.isEmpty,
           let live = CFPreferencesCopyMultiple(
            keys as CFArray,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
           ) as? [String: Any] {
            for (key, value) in live where merged[key] == nil {
                merged[key] = value
            }
        }
        if merged.isEmpty { return nil }
        return expandingBookmarks(merged)
    }

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func expandingBookmarks(_ values: [String: Any]) -> [String: Any] {
        var copy = values
        for (key, value) in values {
            guard let data = value as? Data else { continue }
            var stale = false
            let options: URL.BookmarkResolutionOptions = [.withoutUI, .withSecurityScope]
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                copy[key] = url.path
            } else if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                copy[key] = url.path
            }
        }
        return copy
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
