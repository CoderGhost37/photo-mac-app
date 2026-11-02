import AppKit

/// Security-scoped bookmarks for folders the user picks.
/// The bookmark is stored in the local index so the same folder can be read
/// after it is renamed or the app is relaunched.
enum FolderAccess {
    struct Resolved {
        var url: URL
        var isStale: Bool
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) -> Resolved? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return Resolved(url: url, isStale: isStale)
    }
}
