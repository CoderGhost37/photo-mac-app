import Foundation
import GRDB

public enum IndexError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case sourceRootMissing(String)
    case notAFolderSource(String)

    public var description: String {
        switch self {
        case .sourceRootMissing(let path):
            return "Folder is not available: \(path)"
        case .notAFolderSource(let id):
            return "Source \(id) is not a folder."
        }
    }

    public var errorDescription: String? { description }
}

public final class IndexDatabase: Sendable {
    let db: DatabaseQueue

    public init(path: String) throws {
        if path != ":memory:" {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
        }
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        if path == ":memory:" {
            self.db = try DatabaseQueue(configuration: configuration)
        } else {
            self.db = try DatabaseQueue(path: path, configuration: configuration)
        }
        try Self.migrator.migrate(self.db)
        try backfillSearchKeywords()
    }

    public static func inMemory() throws -> IndexDatabase {
        try IndexDatabase(path: ":memory:")
    }

    public func save(source: Source) throws {
        try db.write { database in
            try source.save(database)
        }
    }

    public func sources() throws -> [Source] {
        try db.read { database in
            try Source.fetchAll(database, sql: "SELECT * FROM source ORDER BY displayName COLLATE NOCASE, id")
        }
    }

    public func source(id: String) throws -> Source? {
        try db.read { database in
            try Source.fetchOne(database, sql: "SELECT * FROM source WHERE id = ?", arguments: [id])
        }
    }

    public func deleteSource(id: String) throws {
        try db.write { database in
            let rows = try Row.fetchAll(database, sql: "SELECT id FROM asset WHERE sourceID = ?", arguments: [id])
            let ids = rows.compactMap { $0["id"] as String? }
            try deleteSearchRows(database, assetIDs: ids)
            try database.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
        }
    }

    /// Keeps each built-in source's enabled flag and bookmark, and refreshes its path.
    public func synchronizeBuiltinSources(homeDirectory: URL, captureDirectory: URL) throws -> [Source] {
        let desired = SourceCatalog.builtinSources(homeDirectory: homeDirectory, captureDirectory: captureDirectory)
        try db.write { database in
            let existing = try Source.fetchAll(database)
            for source in desired {
                if var current = existing.first(where: { $0.id == source.id }) {
                    current.rootPath = source.rootPath
                    current.displayName = source.displayName
                    current.kind = source.kind
                    try current.save(database)
                } else {
                    try source.save(database)
                }
            }
        }
        return try sources()
    }

    public func markScanned(sourceID: String, at date: Date) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE source SET lastScanAt = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, sourceID]
            )
        }
    }

    public func applyChanges(inserted: [Asset], updated: [Asset], deletedIDs: [String]) throws {
        guard !inserted.isEmpty || !updated.isEmpty || !deletedIDs.isEmpty else { return }
        try db.write { database in
            for var asset in inserted + updated {
                if let existing = try Asset.fetchOne(database, sql: "SELECT * FROM asset WHERE id = ?", arguments: [asset.id]) {
                    if asset.geocodedPlace?.isEmpty != false,
                       existing.latitude == asset.latitude,
                       existing.longitude == asset.longitude,
                       let kept = existing.geocodedPlace,
                       !kept.isEmpty {
                        asset.geocodedPlace = kept
                    }
                    asset.isHidden = existing.isHidden
                    asset.isFavorite = existing.isFavorite
                }
                try asset.save(database)
                try upsertKeyword(database, asset: asset)
            }
            try deleteSearchRows(database, assetIDs: deletedIDs)
            let chunk = 200
            var index = 0
            while index < deletedIDs.count {
                let end = min(index + chunk, deletedIDs.count)
                let slice = Array(deletedIDs[index..<end])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                try database.execute(
                    sql: "DELETE FROM asset WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(slice)
                )
                index = end
            }
        }
    }

    public func fileSnapshots(sourceID: String) throws -> [FileSnapshot] {
        try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, filePath, fileSize, fileMTime
                FROM asset
                WHERE sourceID = ? AND filePath IS NOT NULL
                """,
                arguments: [sourceID]
            )
            return rows.compactMap { row in
                guard let id: String = row["id"], let filePath: String = row["filePath"] else { return nil }
                let size: Int64 = row["fileSize"] ?? 0
                let mtime: Double? = row["fileMTime"]
                return FileSnapshot(
                    id: id,
                    filePath: filePath,
                    fileSize: size,
                    modifiedAt: mtime.map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }

    public func assets(sourceID: String) throws -> [Asset] {
        try db.read { database in
            try Asset.fetchAll(database, sql: "SELECT * FROM asset WHERE sourceID = ?", arguments: [sourceID])
        }
    }

    public func asset(id: String) throws -> Asset? {
        try db.read { database in
            try Asset.fetchOne(database, sql: "SELECT * FROM asset WHERE id = ?", arguments: [id])
        }
    }

    public func fetchAssets(matching query: LibraryQuery) throws -> [Asset] {
        guard !query.sourceIDs.isEmpty else { return [] }
        return try db.read { database in
            let (sql, arguments) = Self.listSQL(query: query, limit: nil, offset: 0)
            return try Asset.fetchAll(database, sql: sql, arguments: arguments)
        }
    }

    public func fetchAssets(matching query: LibraryQuery, limit: Int, offset: Int) throws -> [Asset] {
        guard !query.sourceIDs.isEmpty, limit > 0, offset >= 0 else { return [] }
        return try db.read { database in
            let (sql, arguments) = Self.listSQL(query: query, limit: limit, offset: offset)
            return try Asset.fetchAll(database, sql: sql, arguments: arguments)
        }
    }

    public func countAssets(matching query: LibraryQuery) throws -> Int {
        guard !query.sourceIDs.isEmpty else { return 0 }
        return try db.read { database in
            let filter = Self.assetFilter(query: query, qualify: false)
            let sql = "SELECT COUNT(*) FROM asset WHERE \(filter.sql)"
            return try Int.fetchOne(database, sql: sql, arguments: filter.arguments) ?? 0
        }
    }

    /// `bySource` counts every indexed source. Kind totals and `enabledTotal` include only `enabledSourceIDs`.
    public func libraryCounts(enabledSourceIDs: [String]) throws -> LibraryCounts {
        try db.read { database in
            let sourceRows = try Row.fetchAll(
                database,
                sql: "SELECT sourceID, COUNT(*) AS n FROM asset WHERE isHidden = 0 GROUP BY sourceID"
            )
            var bySource: [String: Int] = [:]
            for row in sourceRows {
                if let id: String = row["sourceID"], let count: Int = row["n"] {
                    bySource[id] = count
                }
            }
            var byKind: [MediaKind: Int] = [:]
            var enabledTotal = 0
            if !enabledSourceIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: enabledSourceIDs.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT mediaKind, COUNT(*) AS n FROM asset
                    WHERE sourceID IN (\(placeholders))
                      AND isHidden = 0
                    GROUP BY mediaKind
                    """,
                    arguments: StatementArguments(enabledSourceIDs)
                )
                for row in rows {
                    if let raw: String = row["mediaKind"], let kind = MediaKind(rawValue: raw), let count: Int = row["n"] {
                        byKind[kind] = count
                        enabledTotal += count
                    }
                }
            }
            let hiddenCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM asset WHERE isHidden = 1") ?? 0
            var favoriteCount = 0
            if !enabledSourceIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: enabledSourceIDs.count).joined(separator: ",")
                favoriteCount = try Int.fetchOne(
                    database,
                    sql: """
                    SELECT COUNT(*) FROM asset
                    WHERE sourceID IN (\(placeholders))
                      AND isHidden = 0
                      AND isFavorite = 1
                    """,
                    arguments: StatementArguments(enabledSourceIDs)
                ) ?? 0
            }
            return LibraryCounts(
                bySource: bySource,
                byMediaKind: byKind,
                enabledTotal: enabledTotal,
                hiddenCount: hiddenCount,
                favoriteCount: favoriteCount
            )
        }
    }

    /// Sets the index flag only. The file on disk is not opened for writing.
    public func setFavorite(_ favorite: Bool, assetIDs: [String]) throws {
        guard !assetIDs.isEmpty else { return }
        try db.write { database in
            let chunk = 200
            var index = 0
            while index < assetIDs.count {
                let end = min(index + chunk, assetIDs.count)
                let slice = Array(assetIDs[index..<end])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                var arguments = StatementArguments([favorite])
                arguments += StatementArguments(slice)
                try database.execute(
                    sql: "UPDATE asset SET isFavorite = ? WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
                index = end
            }
        }
    }

    /// Sets the index flag only. The file on disk is not opened for writing.
    public func setHidden(_ hidden: Bool, assetIDs: [String]) throws {
        guard !assetIDs.isEmpty else { return }
        try db.write { database in
            let chunk = 200
            var index = 0
            while index < assetIDs.count {
                let end = min(index + chunk, assetIDs.count)
                let slice = Array(assetIDs[index..<end])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                var arguments = StatementArguments([hidden])
                arguments += StatementArguments(slice)
                try database.execute(
                    sql: "UPDATE asset SET isHidden = ? WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
                index = end
            }
        }
    }

    public func importSignatures() throws -> Set<String> {
        try db.read { database in
            let rows = try String.fetchAll(database, sql: "SELECT signature FROM device_import")
            return Set(rows)
        }
    }

    public func recordImports(_ records: [(signature: String, relativePath: String)], at date: Date) throws {
        guard !records.isEmpty else { return }
        try db.write { database in
            for record in records {
                try database.execute(
                    sql: """
                    INSERT INTO device_import (signature, relativePath, importedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(signature) DO UPDATE SET
                      relativePath = excluded.relativePath,
                      importedAt = excluded.importedAt
                    """,
                    arguments: [record.signature, record.relativePath, date.timeIntervalSince1970]
                )
            }
        }
    }

    /// Adds or refreshes screenshot-tool folders. An existing enabled flag is kept.
    /// A tool that is not in `tools` is left alone, so a missing preference file does not drop the index.
    public func synchronizeCaptureTools(_ tools: [Source]) throws {
        guard !tools.isEmpty else { return }
        try db.write { database in
            let existing = try Source.fetchAll(database)
            for source in tools {
                if var current = existing.first(where: { $0.id == source.id }) {
                    current.rootPath = source.rootPath
                    current.displayName = source.displayName
                    current.kind = source.kind
                    try current.save(database)
                } else {
                    try source.save(database)
                }
            }
        }
    }

    private static func listSQL(query: LibraryQuery, limit: Int?, offset: Int) -> (String, StatementArguments) {
        let filter = assetFilter(query: query, qualify: false)
        var sql = """
        SELECT * FROM asset
        WHERE \(filter.sql)
        ORDER BY (createdAt IS NULL), createdAt DESC, id ASC
        """
        var arguments = filter.arguments
        if let limit {
            sql += "\nLIMIT ? OFFSET ?"
            arguments += StatementArguments([limit, offset])
        }
        return (sql, arguments)
    }

    /// Shared WHERE body for list, count, and search. `qualify` prefixes columns with `asset.`.
    static func assetFilter(query: LibraryQuery, qualify: Bool) -> (sql: String, arguments: StatementArguments) {
        let source = qualify ? "asset.sourceID" : "sourceID"
        let kind = qualify ? "asset.mediaKind" : "mediaKind"
        let hidden = qualify ? "asset.isHidden" : "isHidden"
        let favorite = qualify ? "asset.isFavorite" : "isFavorite"
        let created = qualify ? "asset.createdAt" : "createdAt"
        let placeholders = Array(repeating: "?", count: query.sourceIDs.count).joined(separator: ",")
        var sql = """
        \(source) IN (\(placeholders)) AND \(kind) = COALESCE(?, \(kind)) AND \(hidden) = ?
        """
        var arguments = StatementArguments(query.sourceIDs)
            + StatementArguments([query.mediaKind?.rawValue, query.visibility == .hidden ? 1 : 0])
        if query.favoritesOnly {
            sql += " AND \(favorite) = 1"
        }
        if let createdAfter = query.createdAfter {
            sql += " AND \(created) >= ?"
            arguments += StatementArguments([createdAfter.timeIntervalSince1970])
        }
        return (sql, arguments)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-library") { database in
            try database.create(table: "source") { table in
                table.primaryKey("id", .text)
                table.column("kind", .text).notNull()
                table.column("displayName", .text).notNull()
                table.column("rootPath", .text)
                table.column("bookmarkData", .blob)
                table.column("enabled", .boolean).notNull()
                table.column("lastScanAt", .double)
            }
            try database.create(table: "asset") { table in
                table.primaryKey("id", .text)
                table.column("sourceID", .text).notNull()
                    .references("source", onDelete: .cascade)
                table.column("filePath", .text)
                table.column("photosLocalIdentifier", .text)
                table.column("mediaKind", .text).notNull()
                table.column("createdAt", .double)
                table.column("modifiedAt", .double)
                table.column("pixelWidth", .integer)
                table.column("pixelHeight", .integer)
                table.column("fileSize", .integer)
                table.column("duration", .double)
                table.column("latitude", .double)
                table.column("longitude", .double)
                table.column("contentHash", .text)
                table.column("cameraMake", .text)
                table.column("cameraModel", .text)
                table.column("lensModel", .text)
                table.column("iso", .integer)
                table.column("aperture", .double)
                table.column("shutterSpeed", .double)
                table.column("focalLength", .double)
                table.column("fileMTime", .double)
                table.column("indexedAt", .double)
            }
            try database.create(index: "asset_source_created", on: "asset", columns: ["sourceID", "createdAt"])
            try database.create(index: "asset_kind_created", on: "asset", columns: ["mediaKind", "createdAt"])
            try database.create(
                index: "asset_source_path",
                on: "asset",
                columns: ["sourceID", "filePath"],
                unique: true
            )
        }
        migrator.registerMigration("v2-search") { database in
            for statement in SearchSchema.statements {
                try database.execute(sql: statement)
            }
        }
        migrator.registerMigration("v3-memory") { database in
            for statement in MemorySchema.statements {
                try database.execute(sql: statement)
            }
        }
        migrator.registerMigration("v4-hidden-import") { database in
            try database.alter(table: "asset") { table in
                table.add(column: "isHidden", .boolean).notNull().defaults(to: false)
            }
            try database.create(table: "device_import") { table in
                table.primaryKey("signature", .text)
                table.column("relativePath", .text).notNull()
                table.column("importedAt", .double).notNull()
            }
        }
        migrator.registerMigration("v5-favorite") { database in
            try database.alter(table: "asset") { table in
                table.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }
}

public struct FileSnapshot: Equatable, Sendable {
    public var id: String
    public var filePath: String
    public var fileSize: Int64
    public var modifiedAt: Date?

    public init(id: String, filePath: String, fileSize: Int64, modifiedAt: Date?) {
        self.id = id
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

extension Source: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "source"

    public init(row: Row) {
        id = row["id"]
        kind = SourceKind(rawValue: row["kind"]) ?? .folder
        displayName = row["displayName"]
        rootPath = row["rootPath"]
        bookmarkData = row["bookmarkData"]
        enabled = row["enabled"]
        if let stamp: Double = row["lastScanAt"] {
            lastScanAt = Date(timeIntervalSince1970: stamp)
        } else {
            lastScanAt = nil
        }
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["kind"] = kind.rawValue
        container["displayName"] = displayName
        container["rootPath"] = rootPath
        container["bookmarkData"] = bookmarkData
        container["enabled"] = enabled
        container["lastScanAt"] = lastScanAt?.timeIntervalSince1970
    }
}

extension Asset: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "asset"

    public init(row: Row) {
        id = row["id"]
        sourceID = row["sourceID"]
        filePath = row["filePath"]
        photosLocalIdentifier = row["photosLocalIdentifier"]
        mediaKind = MediaKind(rawValue: row["mediaKind"]) ?? .photo
        createdAt = Self.date(row, "createdAt")
        modifiedAt = Self.date(row, "modifiedAt")
        pixelWidth = row["pixelWidth"]
        pixelHeight = row["pixelHeight"]
        fileSize = row["fileSize"]
        duration = row["duration"]
        latitude = row["latitude"]
        longitude = row["longitude"]
        placeName = row["placeName"]
        geocodedPlace = row["geocodedPlace"]
        contentHash = row["contentHash"]
        cameraMake = row["cameraMake"]
        cameraModel = row["cameraModel"]
        lensModel = row["lensModel"]
        iso = row["iso"]
        aperture = row["aperture"]
        shutterSpeed = row["shutterSpeed"]
        focalLength = row["focalLength"]
        fileMTime = Self.date(row, "fileMTime")
        indexedAt = Self.date(row, "indexedAt")
        isHidden = row["isHidden"] ?? false
        isFavorite = row["isFavorite"] ?? false
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["sourceID"] = sourceID
        container["filePath"] = filePath
        container["photosLocalIdentifier"] = photosLocalIdentifier
        container["mediaKind"] = mediaKind.rawValue
        container["createdAt"] = createdAt?.timeIntervalSince1970
        container["modifiedAt"] = modifiedAt?.timeIntervalSince1970
        container["pixelWidth"] = pixelWidth
        container["pixelHeight"] = pixelHeight
        container["fileSize"] = fileSize
        container["duration"] = duration
        container["latitude"] = latitude
        container["longitude"] = longitude
        container["placeName"] = placeName
        container["geocodedPlace"] = geocodedPlace
        container["contentHash"] = contentHash
        container["cameraMake"] = cameraMake
        container["cameraModel"] = cameraModel
        container["lensModel"] = lensModel
        container["iso"] = iso
        container["aperture"] = aperture
        container["shutterSpeed"] = shutterSpeed
        container["focalLength"] = focalLength
        container["fileMTime"] = fileMTime?.timeIntervalSince1970
        container["indexedAt"] = indexedAt?.timeIntervalSince1970
        container["isHidden"] = isHidden
        container["isFavorite"] = isFavorite
    }

    private static func date(_ row: Row, _ column: String) -> Date? {
        let stamp: Double? = row[column]
        return stamp.map { Date(timeIntervalSince1970: $0) }
    }
}
