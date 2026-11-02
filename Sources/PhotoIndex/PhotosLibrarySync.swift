import Foundation

/// Diffs a read-only Photos library fetch against the index.
/// PhotoKit itself stays in the app; this only compares already-built assets.
public enum PhotosLibrarySync {
    public static func changes(existing: [Asset], incoming: [Asset]) -> (inserted: [Asset], updated: [Asset], deletedIDs: [String], skipped: Int) {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var incomingIDs = Set<String>()
        var inserted: [Asset] = []
        var updated: [Asset] = []
        var skipped = 0
        for asset in incoming {
            incomingIDs.insert(asset.id)
            if let prior = existingByID[asset.id] {
                if sameSnapshot(prior, asset) {
                    skipped += 1
                } else {
                    updated.append(asset)
                }
            } else {
                inserted.append(asset)
            }
        }
        let deleted = existing.map(\.id).filter { !incomingIDs.contains($0) }
        return (inserted, updated, deleted, skipped)
    }

    private static func sameSnapshot(_ lhs: Asset, _ rhs: Asset) -> Bool {
        lhs.mediaKind == rhs.mediaKind
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.fileSize == rhs.fileSize
            && datesMatch(lhs.modifiedAt, rhs.modifiedAt)
            && durationsMatch(lhs.duration, rhs.duration)
            && lhs.photosLocalIdentifier == rhs.photosLocalIdentifier
    }

    private static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left.timeIntervalSince1970 - right.timeIntervalSince1970) < 1
        default:
            return false
        }
    }

    private static func durationsMatch(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left - right) < 0.01
        default:
            return false
        }
    }
}
