import Foundation

public struct LibraryQuery: Equatable, Sendable {
    /// Sources to include. An empty list matches nothing.
    public var sourceIDs: [String]
    /// `nil` includes every media kind.
    public var mediaKind: MediaKind?

    public init(sourceIDs: [String], mediaKind: MediaKind? = nil) {
        self.sourceIDs = sourceIDs
        self.mediaKind = mediaKind
    }
}

public struct LibraryCounts: Equatable, Sendable {
    public var bySource: [String: Int]
    public var byMediaKind: [MediaKind: Int]
    public var enabledTotal: Int

    public init(bySource: [String: Int], byMediaKind: [MediaKind: Int], enabledTotal: Int) {
        self.bySource = bySource
        self.byMediaKind = byMediaKind
        self.enabledTotal = enabledTotal
    }

    public static let empty = LibraryCounts(bySource: [:], byMediaKind: [:], enabledTotal: 0)
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
