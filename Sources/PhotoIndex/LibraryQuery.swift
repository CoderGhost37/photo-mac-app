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
    /// When true, only favorited items match.
    public var favoritesOnly: Bool
    /// Inclusive lower bound on `createdAt`. Undated items are left out.
    public var createdAfter: Date?

    public init(
        sourceIDs: [String],
        mediaKind: MediaKind? = nil,
        visibility: LibraryVisibility = .visible,
        favoritesOnly: Bool = false,
        createdAfter: Date? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.mediaKind = mediaKind
        self.visibility = visibility
        self.favoritesOnly = favoritesOnly
        self.createdAfter = createdAfter
    }
}

public struct LibraryCounts: Equatable, Sendable {
    public var bySource: [String: Int]
    public var byMediaKind: [MediaKind: Int]
    public var enabledTotal: Int
    /// Hidden items across every source. They are left out of the other counts.
    public var hiddenCount: Int
    /// Favorites among enabled sources. Hidden items are not included.
    public var favoriteCount: Int

    public init(
        bySource: [String: Int],
        byMediaKind: [MediaKind: Int],
        enabledTotal: Int,
        hiddenCount: Int,
        favoriteCount: Int = 0
    ) {
        self.bySource = bySource
        self.byMediaKind = byMediaKind
        self.enabledTotal = enabledTotal
        self.hiddenCount = hiddenCount
        self.favoriteCount = favoriteCount
    }

    public static let empty = LibraryCounts(bySource: [:], byMediaKind: [:], enabledTotal: 0, hiddenCount: 0, favoriteCount: 0)
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
