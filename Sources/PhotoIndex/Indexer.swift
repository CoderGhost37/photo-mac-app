import Foundation

public struct Indexer: Sendable {
    private let database: IndexDatabase
    private let metadataReader: any MetadataReading
    private let hasher: any ContentHashing

    public init(
        database: IndexDatabase,
        metadataReader: any MetadataReading,
        hasher: any ContentHashing = SHA256FileHasher()
    ) {
        self.database = database
        self.metadataReader = metadataReader
        self.hasher = hasher
    }

    /// Incremental folder scan. Unchanged files (same size and modification time) are skipped.
    /// A missing folder is reported and does not wipe the existing index.
    public func scan(
        _ source: Source,
        onProgress: (@Sendable (_ examined: Int, _ total: Int) -> Void)? = nil
    ) async throws -> ScanStats {
        guard source.kind != .photosLibrary else {
            throw IndexError.notAFolderSource(source.id)
        }
        guard let root = source.rootPath, !root.isEmpty else {
            throw IndexError.sourceRootMissing(source.id)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IndexError.sourceRootMissing(root)
        }

        let discovered = FileCatalog.entries(in: URL(fileURLWithPath: root, isDirectory: true), sourceKind: source.kind)
        let snapshots = try database.fileSnapshots(sourceID: source.id)
        let rootPath = SourceCatalog.normalizedDirectory(URL(fileURLWithPath: root)).path
        var existingByRelative: [String: FileSnapshot] = [:]
        for snapshot in snapshots {
            if let relative = FileCatalog.relativePath(file: snapshot.filePath, root: rootPath) {
                existingByRelative[relative] = snapshot
            }
        }

        var pendingInserts: [Asset] = []
        var pendingUpdates: [Asset] = []
        var insertedCount = 0
        var updatedCount = 0
        var skipped = 0
        var seen = Set<String>()
        let total = discovered.count
        onProgress?(0, total)

        for (index, entry) in discovered.enumerated() {
            seen.insert(entry.relativePath)
            if let prior = existingByRelative[entry.relativePath],
               prior.fileSize == entry.fileSize,
               ModificationTime.unchanged(stored: prior.modifiedAt, current: entry.modifiedAt) {
                skipped += 1
            } else {
                let metadata = await metadataReader.metadata(forFileAt: URL(fileURLWithPath: entry.filePath))
                let hash = try hasher.hash(ofFileAt: URL(fileURLWithPath: entry.filePath))
                let asset = makeAsset(entry: entry, sourceID: source.id, metadata: metadata, hash: hash)
                if existingByRelative[entry.relativePath] == nil {
                    pendingInserts.append(asset)
                    insertedCount += 1
                } else {
                    pendingUpdates.append(asset)
                    updatedCount += 1
                }
            }
            if pendingInserts.count + pendingUpdates.count >= 200 {
                try database.applyChanges(inserted: pendingInserts, updated: pendingUpdates, deletedIDs: [])
                pendingInserts.removeAll(keepingCapacity: true)
                pendingUpdates.removeAll(keepingCapacity: true)
            }
            if index % 50 == 0 {
                onProgress?(index + 1, total)
            }
        }

        let deleted = snapshots.compactMap { snapshot -> String? in
            guard let relative = FileCatalog.relativePath(file: snapshot.filePath, root: rootPath) else {
                return snapshot.id
            }
            return seen.contains(relative) ? nil : snapshot.id
        }
        try database.applyChanges(inserted: pendingInserts, updated: pendingUpdates, deletedIDs: deleted)
        try database.markScanned(sourceID: source.id, at: Date())
        onProgress?(total, total)
        return ScanStats(inserted: insertedCount, updated: updatedCount, deleted: deleted.count, skipped: skipped)
    }

    public func applyPhotosLibrary(existing: [Asset], incoming: [Asset], sourceID: String) throws -> ScanStats {
        let diff = PhotosLibrarySync.changes(existing: existing, incoming: incoming)
        try database.applyChanges(inserted: diff.inserted, updated: diff.updated, deletedIDs: diff.deletedIDs)
        try database.markScanned(sourceID: sourceID, at: Date())
        return ScanStats(
            inserted: diff.inserted.count,
            updated: diff.updated.count,
            deleted: diff.deletedIDs.count,
            skipped: diff.skipped
        )
    }

    private func makeAsset(entry: CatalogEntry, sourceID: String, metadata: ExtractedMetadata, hash: String) -> Asset {
        Asset(
            id: AssetID.file(sourceID: sourceID, relativePath: entry.relativePath),
            sourceID: sourceID,
            filePath: entry.filePath,
            photosLocalIdentifier: nil,
            mediaKind: entry.mediaKind,
            createdAt: metadata.createdAt ?? entry.createdAt ?? entry.modifiedAt,
            modifiedAt: entry.modifiedAt,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            fileSize: entry.fileSize,
            duration: metadata.duration,
            latitude: metadata.latitude,
            longitude: metadata.longitude,
            contentHash: hash,
            cameraMake: metadata.cameraMake,
            cameraModel: metadata.cameraModel,
            lensModel: metadata.lensModel,
            iso: metadata.iso,
            aperture: metadata.aperture,
            shutterSpeed: metadata.shutterSpeed,
            focalLength: metadata.focalLength,
            fileMTime: entry.modifiedAt,
            indexedAt: Date()
        )
    }
}
