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
            for asset in inserted + updated {
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
            let placeholders = Array(repeating: "?", count: query.sourceIDs.count).joined(separator: ",")
            let sql = """
            SELECT COUNT(*) FROM asset
            WHERE sourceID IN (\(placeholders))
              AND mediaKind = COALESCE(?, mediaKind)
            """
            let arguments = StatementArguments(query.sourceIDs) + StatementArguments([query.mediaKind?.rawValue])
            return try Int.fetchOne(database, sql: sql, arguments: arguments) ?? 0
        }
    }

    /// `bySource` counts every indexed source. Kind totals and `enabledTotal` include only `enabledSourceIDs`.
    public func libraryCounts(enabledSourceIDs: [String]) throws -> LibraryCounts {
        try db.read { database in
            let sourceRows = try Row.fetchAll(database, sql: "SELECT sourceID, COUNT(*) AS n FROM asset GROUP BY sourceID")
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
            return LibraryCounts(bySource: bySource, byMediaKind: byKind, enabledTotal: enabledTotal)
        }
    }

    private static func listSQL(query: LibraryQuery, limit: Int?, offset: Int) -> (String, StatementArguments) {
        let placeholders = Array(repeating: "?", count: query.sourceIDs.count).joined(separator: ",")
        var sql = """
        SELECT * FROM asset
        WHERE sourceID IN (\(placeholders))
          AND mediaKind = COALESCE(?, mediaKind)
        ORDER BY (createdAt IS NULL), createdAt DESC, id ASC
        """
        var arguments = StatementArguments(query.sourceIDs) + StatementArguments([query.mediaKind?.rawValue])
        if let limit {
            sql += "\nLIMIT ? OFFSET ?"
            arguments += StatementArguments([limit, offset])
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
    }

    private static func date(_ row: Row, _ column: String) -> Date? {
        let stamp: Double? = row[column]
        return stamp.map { Date(timeIntervalSince1970: $0) }
    }
}
