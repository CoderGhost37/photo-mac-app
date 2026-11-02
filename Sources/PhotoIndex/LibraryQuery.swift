import Foundation

public enum LibraryVisibility: Equatable, Sendable {
    /// Indexed items that are not hidden.
    case visible
    /// The Hidden album.
    case hidden
}

public struct LibraryQuery: Equatable, Sendable {
    /// Sources to include. An empty list matches nothing.
    public var sourceIDs: [String]
    /// `nil` includes every media kind.
    public var mediaKind: MediaKind?
    public var visibility: LibraryVisibility

    public init(sourceIDs: [String], mediaKind: MediaKind? = nil, visibility: LibraryVisibility = .visible) {
        self.sourceIDs = sourceIDs
        self.mediaKind = mediaKind
        self.visibility = visibility
    }
}

public struct LibraryCounts: Equatable, Sendable {
    public var bySource: [String: Int]
    public var byMediaKind: [MediaKind: Int]
    public var enabledTotal: Int
    /// Hidden items across every source. They are left out of the other counts.
    public var hiddenCount: Int

    public init(bySource: [String: Int], byMediaKind: [MediaKind: Int], enabledTotal: Int, hiddenCount: Int) {
        self.bySource = bySource
        self.byMediaKind = byMediaKind
        self.enabledTotal = enabledTotal
        self.hiddenCount = hiddenCount
    }

    public static let empty = LibraryCounts(bySource: [:], byMediaKind: [:], enabledTotal: 0, hiddenCount: 0)
}

public struct ScanStats: Equatable, Sendable {
    public var inserted: Int
    public var updated: Int
    public var deleted: Int
    public var skipped: Int

    public init(inserted: Int, updated: Int, deleted: Int, skipped: Int) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
        self.skipped = skipped
    }

    public static let zero = ScanStats(inserted: 0, updated: 0, deleted: 0, skipped: 0)
}
