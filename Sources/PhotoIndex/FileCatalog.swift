import Foundation

struct CatalogEntry: Equatable, Sendable {
    var relativePath: String
    var filePath: String
    var fileSize: Int64
    var modifiedAt: Date
    var createdAt: Date?
    var mediaKind: MediaKind
}

enum FileCatalog {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "dng"
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv"
    ]
    private static let skippedDirectoryExtensions: Set<String> = [
        "photoslibrary", "app", "bundle", "framework"
    ]

    static func entries(in root: URL, sourceKind: SourceKind) -> [CatalogEntry] {
        let rootPath = SourceCatalog.normalizedDirectory(root).path
        var result: [CatalogEntry] = []
        var pending = [rootPath]
        let fileManager = FileManager.default
        while let directory = pending.popLast() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if skippedDirectoryExtensions.contains(ext) { continue }
                    pending.append(path)
                    continue
                }
                guard let relative = relativePath(file: path, root: rootPath),
                      let kind = MediaClassifier.kind(relativePath: relative, sourceKind: sourceKind) else {
                    continue
                }
                let attributes = try? fileManager.attributesOfItem(atPath: path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let modified = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
                let created = attributes?[.creationDate] as? Date
                result.append(CatalogEntry(
                    relativePath: relative,
                    filePath: path,
                    fileSize: size,
                    modifiedAt: modified,
                    createdAt: created,
                    mediaKind: kind
                ))
            }
        }
        return result
    }

    static func relativePath(file: String, root: String) -> String? {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        let file = file.count > 1 && file.hasSuffix("/") ? String(file.dropLast()) : file
        guard file == root || file.hasPrefix(root + "/") else { return nil }
        let relative = String(file.dropFirst(root.count + (file == root ? 0 : 1)))
        return relative.isEmpty ? nil : relative
    }
}

enum MediaClassifier {
    static func kind(relativePath: String, sourceKind: SourceKind) -> MediaKind? {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let isImage = FileCatalog.imageExtensions.contains(ext)
        let isVideo = FileCatalog.videoExtensions.contains(ext)
        guard isImage || isVideo else { return nil }
        switch sourceKind {
        case .screenshots:
            return isImage ? .screenshot : nil
        case .screenRecordings:
            return isVideo ? .screenRecording : nil
        case .downloads, .folder, .photosLibrary:
            if isVideo {
                return looksLikeScreenRecording(relativePath) ? .screenRecording : .video
            }
            return looksLikeScreenshot(relativePath) ? .screenshot : .photo
        case .captureTool:
            return isVideo ? .screenRecording : .screenshot
        }
    }

    private static func looksLikeScreenshot(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.contains("screenshot") || name.contains("screen shot") || name.contains("screen_shot")
    }

    private static func looksLikeScreenRecording(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.contains("screen recording") || name.contains("screen_recording")
    }
}

enum ModificationTime {
    /// One-second window covers APFS timestamps stored as doubles and HFS second resolution.
    static func unchanged(stored: Date?, current: Date) -> Bool {
        guard let stored else { return false }
        return abs(stored.timeIntervalSince1970 - current.timeIntervalSince1970) < 1
    }
}
