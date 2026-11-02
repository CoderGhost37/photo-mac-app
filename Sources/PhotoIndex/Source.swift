import Foundation

/// A place Stillroom is allowed to read. The files themselves stay put.
public struct Source: Identifiable, Equatable, Sendable {
    public static let screenshotsID = "builtin.screenshots"
    public static let photosLibraryID = "builtin.photos"
    public static let downloadsID = "builtin.downloads"
    public static let screenRecordingsID = "builtin.screen-recordings"

    public var id: String
    public var kind: SourceKind
    public var displayName: String
    public var rootPath: String?
    public var bookmarkData: Data?
    public var enabled: Bool
    public var lastScanAt: Date?

    public init(
        id: String,
        kind: SourceKind,
        displayName: String,
        rootPath: String?,
        bookmarkData: Data?,
        enabled: Bool,
        lastScanAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.rootPath = rootPath
        self.bookmarkData = bookmarkData
        self.enabled = enabled
        self.lastScanAt = lastScanAt
    }

    public var isFolderBacked: Bool {
        kind != .photosLibrary
    }
}

public enum SourceCatalog {
    /// Built-in sources. Screenshots and screen recordings share the folder
    /// reported by `com.apple.screencapture` (Desktop when unset) and are split
    /// by file type so each can be enabled on its own.
    public static func builtinSources(homeDirectory: URL, captureDirectory: URL) -> [Source] {
        let home = normalizedDirectory(homeDirectory)
        let capture = normalizedDirectory(captureDirectory)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        return [
            Source(
                id: Source.screenshotsID,
                kind: .screenshots,
                displayName: "Screenshots",
                rootPath: capture.path,
                bookmarkData: nil,
                enabled: true,
                lastScanAt: nil
            ),
            Source(
                id: Source.photosLibraryID,
                kind: .photosLibrary,
                displayName: "Photos Library",
                rootPath: nil,
                bookmarkData: nil,
                enabled: true,
                lastScanAt: nil
            ),
            Source(
                id: Source.downloadsID,
                kind: .downloads,
                displayName: "Downloads",
                rootPath: downloads.path,
                bookmarkData: nil,
                enabled: true,
                lastScanAt: nil
            ),
            Source(
                id: Source.screenRecordingsID,
                kind: .screenRecordings,
                displayName: "Screen Recordings",
                rootPath: capture.path,
                bookmarkData: nil,
                enabled: true,
                lastScanAt: nil
            )
        ]
    }

    public static func customFolder(displayName: String, rootPath: String, bookmarkData: Data?) -> Source {
        Source(
            id: "folder.\(UUID().uuidString.lowercased())",
            kind: .folder,
            displayName: displayName,
            rootPath: rootPath,
            bookmarkData: bookmarkData,
            enabled: true,
            lastScanAt: nil
        )
    }

    public static func normalizedDirectory(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
