import Foundation
import GRDB

enum MemorySchema {
    static let statements: [String] = [
        "ALTER TABLE asset ADD COLUMN geocodedPlace TEXT",
        """
        CREATE TABLE place_cache (
          cacheKey TEXT PRIMARY KEY,
          latitude REAL NOT NULL,
          longitude REAL NOT NULL,
          placeName TEXT,
          lookedUpAt REAL NOT NULL
        )
        """,
        """
        CREATE TABLE subject_sample (
          id TEXT PRIMARY KEY,
          assetID TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
          kind TEXT NOT NULL,
          boxX REAL NOT NULL,
          boxY REAL NOT NULL,
          boxWidth REAL NOT NULL,
          boxHeight REAL NOT NULL,
          confidence REAL NOT NULL,
          vector BLOB NOT NULL
        )
        """,
        "CREATE INDEX subject_sample_asset ON subject_sample(assetID)",
        """
        CREATE TABLE subject_cluster (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          name TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE subject_member (
          sampleID TEXT PRIMARY KEY REFERENCES subject_sample(id) ON DELETE CASCADE,
          clusterID TEXT NOT NULL REFERENCES subject_cluster(id) ON DELETE CASCADE,
          assetID TEXT NOT NULL
        )
        """,
        "CREATE INDEX subject_member_cluster ON subject_member(clusterID)",
        """
        CREATE TABLE subject_rejection (
          clusterID TEXT NOT NULL REFERENCES subject_cluster(id) ON DELETE CASCADE,
          assetID TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
          PRIMARY KEY (clusterID, assetID)
        )
        """,
        """
        CREATE TABLE scene_label (
          id INTEGER PRIMARY KEY,
          assetID TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
          label TEXT NOT NULL,
          confidence REAL NOT NULL
        )
        """,
        "CREATE INDEX scene_label_asset ON scene_label(assetID)",
        """
        CREATE TABLE image_print (
          assetID TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
          vector BLOB NOT NULL
        )
        """,
        """
        CREATE TABLE understanding_scan (
          assetID TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
          contentToken TEXT NOT NULL,
          scannedAt REAL NOT NULL
        )
        """
    ]
}

extension IndexDatabase {
    public func assets(ids: [String]) throws -> [Asset] {
        guard !ids.isEmpty else { return [] }
        let found = try db.read { database in
            try Self.fetchAssets(database, ids: ids)
        }
        return ids.compactMap { found[$0] }
    }

    public func geotaggedAssets(sourceIDs: [String]) throws -> [Asset] {
        guard !sourceIDs.isEmpty else { return [] }
        return try db.read { database in
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            return try Asset.fetchAll(
                database,
                sql: """
                SELECT * FROM asset
                WHERE sourceID IN (\(placeholders))
                  AND latitude IS NOT NULL
                  AND longitude IS NOT NULL
                ORDER BY (createdAt IS NULL), createdAt DESC, id ASC
                """,
                arguments: StatementArguments(sourceIDs)
            )
        }
    }

    public func geoPoints(sourceIDs: [String]) throws -> [GeoPoint] {
        guard !sourceIDs.isEmpty else { return [] }
        return try db.read { database in
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, latitude, longitude FROM asset
                WHERE sourceID IN (\(placeholders))
                  AND latitude IS NOT NULL
                  AND longitude IS NOT NULL
                """,
                arguments: StatementArguments(sourceIDs)
            )
            return rows.compactMap { row in
                guard let id: String = row["id"], let latitude: Double = row["latitude"], let longitude: Double = row["longitude"] else {
                    return nil
                }
                return GeoPoint(id: id, latitude: latitude, longitude: longitude)
            }
        }
    }

    public func placeLookups(sourceIDs: [String], limit: Int) throws -> [PlaceLookup] {
        guard !sourceIDs.isEmpty, limit > 0 else { return [] }
        return try db.read { database in
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, latitude, longitude FROM asset
                WHERE sourceID IN (\(placeholders))
                  AND latitude IS NOT NULL
                  AND longitude IS NOT NULL
                  AND (geocodedPlace IS NULL OR geocodedPlace = '')
                ORDER BY id ASC
                """,
                arguments: StatementArguments(sourceIDs)
            )
            var grouped: [String: PlaceLookup] = [:]
            var order: [String] = []
            for row in rows {
                guard let id: String = row["id"],
                      let latitude: Double = row["latitude"],
                      let longitude: Double = row["longitude"],
                      let key = PlaceName.cacheKey(latitude: latitude, longitude: longitude) else { continue }
                if var existing = grouped[key] {
                    existing.assetIDs.append(id)
                    grouped[key] = existing
                } else if order.count < limit {
                    order.append(key)
                    grouped[key] = PlaceLookup(cacheKey: key, latitude: latitude, longitude: longitude, assetIDs: [id])
                }
            }
            return order.compactMap { grouped[$0] }
        }
    }

    public func cachedPlace(key: String) throws -> CachedPlace? {
        try db.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT cacheKey, latitude, longitude, placeName, lookedUpAt FROM place_cache WHERE cacheKey = ?",
                arguments: [key]
            ) else { return nil }
            guard let key: String = row["cacheKey"] else { return nil }
            let looked: Double = row["lookedUpAt"] ?? 0
            let latitude: Double = row["latitude"] ?? 0
            let longitude: Double = row["longitude"] ?? 0
            let placeName: String? = row["placeName"]
            return CachedPlace(
                key: key,
                latitude: latitude,
                longitude: longitude,
                placeName: placeName,
                lookedUpAt: Date(timeIntervalSince1970: looked)
            )
        }
    }

    public func savePlaceCache(key: String, latitude: Double, longitude: Double, placeName: String?, lookedUpAt: Date) throws {
        try db.write { database in
            try database.execute(
                sql: """
                INSERT INTO place_cache (cacheKey, latitude, longitude, placeName, lookedUpAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                  latitude = excluded.latitude,
                  longitude = excluded.longitude,
                  placeName = excluded.placeName,
                  lookedUpAt = excluded.lookedUpAt
                """,
                arguments: [key, latitude, longitude, placeName, lookedUpAt.timeIntervalSince1970]
            )
        }
    }

    public func setGeocodedPlace(assetIDs: [String], placeName: String) throws {
        let trimmed = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !assetIDs.isEmpty else { return }
        try db.write { database in
            for id in assetIDs {
                guard var asset = try Asset.fetchOne(database, sql: "SELECT * FROM asset WHERE id = ?", arguments: [id]) else { continue }
                asset.geocodedPlace = trimmed
                try asset.save(database)
                try upsertKeyword(database, asset: asset)
            }
        }
    }

    public func replaceSubjects(
        assetID: String,
        contentToken: String,
        subjects: [StoredSubject],
        labels: [SceneLabel],
        imageVector: [Float]?,
        scannedAt: Date = Date()
    ) throws {
        try db.write { database in
            let existing = try String.fetchAll(
                database,
                sql: "SELECT id FROM subject_sample WHERE assetID = ?",
                arguments: [assetID]
            )
            let keep = Set(subjects.map(\.id))
            let stale = existing.filter { !keep.contains($0) }
            if !stale.isEmpty {
                let placeholders = Array(repeating: "?", count: stale.count).joined(separator: ",")
                try database.execute(
                    sql: "DELETE FROM subject_sample WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(stale)
                )
            }
            for subject in subjects where subject.assetID == assetID && !subject.vector.isEmpty {
                let blob = VectorBlob.pack(subject.vector)
                try database.execute(
                    sql: """
                    INSERT INTO subject_sample (
                      id, assetID, kind, boxX, boxY, boxWidth, boxHeight, confidence, vector
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      kind = excluded.kind,
                      boxX = excluded.boxX,
                      boxY = excluded.boxY,
                      boxWidth = excluded.boxWidth,
                      boxHeight = excluded.boxHeight,
                      confidence = excluded.confidence,
                      vector = excluded.vector
                    """,
                    arguments: [
                        subject.id, assetID, subject.kind.rawValue,
                        subject.box.x, subject.box.y, subject.box.width, subject.box.height,
                        subject.confidence, blob
                    ]
                )
            }
            try database.execute(sql: "DELETE FROM scene_label WHERE assetID = ?", arguments: [assetID])
            for label in labels {
                let text = label.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try database.execute(
                    sql: "INSERT INTO scene_label (assetID, label, confidence) VALUES (?, ?, ?)",
                    arguments: [assetID, text, label.confidence]
                )
            }
            if let imageVector, !imageVector.isEmpty {
                try database.execute(
                    sql: """
                    INSERT INTO image_print (assetID, vector) VALUES (?, ?)
                    ON CONFLICT(assetID) DO UPDATE SET vector = excluded.vector
                    """,
                    arguments: [assetID, VectorBlob.pack(imageVector)]
                )
            } else {
                try database.execute(sql: "DELETE FROM image_print WHERE assetID = ?", arguments: [assetID])
            }
            try database.execute(
                sql: """
                INSERT INTO understanding_scan (assetID, contentToken, scannedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(assetID) DO UPDATE SET
                  contentToken = excluded.contentToken,
                  scannedAt = excluded.scannedAt
                """,
                arguments: [assetID, contentToken, scannedAt.timeIntervalSince1970]
            )
        }
    }

    public func assignNewSubjects(makeID: @escaping () -> String = { UUID().uuidString }) throws {
        try db.write { database in
            let samples = try Self.loadSamples(database)
            var clusters = try Self.loadClusters(database)
            for kind in [SubjectKind.person, SubjectKind.cat, SubjectKind.dog] {
                let threshold = kind == .person ? SubjectGrouping.personDistance : SubjectGrouping.petDistance
                let subset = samples.filter { $0.kind == kind }
                let existing = clusters.filter { $0.kind == kind }
                let assigned = SubjectGrouping.assign(
                    samples: subset,
                    clusters: existing,
                    threshold: threshold,
                    newID: { _ in "\(kind.rawValue)-\(makeID())" }
                )
                clusters.removeAll { $0.kind == kind }
                clusters.append(contentsOf: assigned)
            }
            try Self.writeClusters(database, clusters: clusters, samples: samples)
        }
    }

    public func renameSubject(clusterID: String, name: String) throws {
        try db.write { database in
            var clusters = try Self.loadClusters(database)
            clusters = SubjectGrouping.rename(clusters, id: clusterID, name: name)
            let samples = try Self.loadSamples(database)
            try Self.writeClusters(database, clusters: clusters, samples: samples)
        }
    }

    public func mergeSubjects(keeping: String, absorbing: String) throws {
        try db.write { database in
            let samples = try Self.loadSamples(database)
            var clusters = try Self.loadClusters(database)
            clusters = SubjectGrouping.merge(clusters: clusters, samples: samples, keeping: keeping, absorbing: absorbing)
            try Self.writeClusters(database, clusters: clusters, samples: samples)
        }
    }

    public func removeSubject(assetID: String, from clusterID: String) throws {
        try db.write { database in
            let samples = try Self.loadSamples(database)
            var clusters = try Self.loadClusters(database)
            clusters = SubjectGrouping.remove(assetID: assetID, from: clusterID, clusters: clusters, samples: samples)
            try Self.writeClusters(database, clusters: clusters, samples: samples)
        }
    }

    public func subjectClusters() throws -> [SubjectClusterRecord] {
        try db.read { database in
            let clusters = try Row.fetchAll(database, sql: "SELECT id, kind, name FROM subject_cluster ORDER BY id")
            var records: [SubjectClusterRecord] = []
            for row in clusters {
                guard let id: String = row["id"], let kind = SubjectKind(rawValue: row["kind"] ?? "") else { continue }
                let name: String = row["name"] ?? ""
                let members = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT subject_member.assetID AS assetID,
                           subject_sample.boxX AS boxX,
                           subject_sample.boxY AS boxY,
                           subject_sample.boxWidth AS boxWidth,
                           subject_sample.boxHeight AS boxHeight,
                           subject_member.sampleID AS sampleID
                    FROM subject_member
                    JOIN subject_sample ON subject_sample.id = subject_member.sampleID
                    WHERE subject_member.clusterID = ?
                    ORDER BY subject_member.sampleID
                    """,
                    arguments: [id]
                )
                var assetIDs: [String] = []
                var seen = Set<String>()
                var coverAssetID: String?
                var coverBox: NormalizedBox?
                for member in members {
                    guard let assetID: String = member["assetID"] else { continue }
                    if seen.insert(assetID).inserted {
                        assetIDs.append(assetID)
                    }
                    if coverAssetID == nil {
                        coverAssetID = assetID
                        coverBox = NormalizedBox(
                            x: member["boxX"] ?? 0,
                            y: member["boxY"] ?? 0,
                            width: member["boxWidth"] ?? 0,
                            height: member["boxHeight"] ?? 0
                        )
                    }
                }
                guard !assetIDs.isEmpty else { continue }
                records.append(SubjectClusterRecord(
                    id: id,
                    kind: kind,
                    name: name,
                    assetIDs: assetIDs,
                    coverAssetID: coverAssetID,
                    coverBox: coverBox
                ))
            }
            return records
        }
    }

    public func duplicateCandidates(sourceIDs: [String]) throws -> [DuplicateCandidate] {
        guard !sourceIDs.isEmpty else { return [] }
        return try db.read { database in
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT asset.id AS id, asset.contentHash AS contentHash, image_print.vector AS vector
                FROM asset
                LEFT JOIN image_print ON image_print.assetID = asset.id
                WHERE asset.sourceID IN (\(placeholders))
                """,
                arguments: StatementArguments(sourceIDs)
            )
            return rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                let hash: String? = row["contentHash"]
                let vector: [Float]?
                if let blob: Data = row["vector"] {
                    vector = VectorBlob.unpack(blob)
                } else {
                    vector = nil
                }
                return DuplicateCandidate(id: id, contentHash: hash, vector: vector)
            }
        }
    }

    public func memoryAssets(sourceIDs: [String]) throws -> [MemoryAsset] {
        guard !sourceIDs.isEmpty else { return [] }
        return try db.read { database in
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, createdAt, latitude, longitude, placeName, geocodedPlace
                FROM asset
                WHERE sourceID IN (\(placeholders))
                """,
                arguments: StatementArguments(sourceIDs)
            )
            let memberRows = try Row.fetchAll(
                database,
                sql: """
                SELECT DISTINCT subject_member.assetID AS assetID, subject_cluster.id AS clusterID, subject_cluster.kind AS kind
                FROM subject_member
                JOIN subject_cluster ON subject_cluster.id = subject_member.clusterID
                JOIN asset ON asset.id = subject_member.assetID
                WHERE asset.sourceID IN (\(placeholders))
                """,
                arguments: StatementArguments(sourceIDs)
            )
            var people: [String: [String]] = [:]
            var pets: [String: [String]] = [:]
            for row in memberRows {
                guard let assetID: String = row["assetID"], let clusterID: String = row["clusterID"] else { continue }
                let kind = SubjectKind(rawValue: row["kind"] ?? "")
                if kind == .person {
                    if !(people[assetID]?.contains(clusterID) ?? false) {
                        people[assetID, default: []].append(clusterID)
                    }
                } else if kind == .cat || kind == .dog {
                    if !(pets[assetID]?.contains(clusterID) ?? false) {
                        pets[assetID, default: []].append(clusterID)
                    }
                }
            }
            let labelRows = try Row.fetchAll(
                database,
                sql: """
                SELECT scene_label.assetID AS assetID, scene_label.label AS label
                FROM scene_label
                JOIN asset ON asset.id = scene_label.assetID
                WHERE asset.sourceID IN (\(placeholders))
                ORDER BY scene_label.confidence DESC
                """,
                arguments: StatementArguments(sourceIDs)
            )
            var labels: [String: [String]] = [:]
            for row in labelRows {
                guard let assetID: String = row["assetID"], let label: String = row["label"] else { continue }
                labels[assetID, default: []].append(label)
            }
            return rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                let created: Double? = row["createdAt"]
                let stored: String? = row["placeName"]
                let geocoded: String? = row["geocodedPlace"]
                let place = PlaceName.searchable(stored: stored, geocoded: geocoded)
                return MemoryAsset(
                    id: id,
                    createdAt: created.map { Date(timeIntervalSince1970: $0) },
                    latitude: row["latitude"],
                    longitude: row["longitude"],
                    placeName: place.isEmpty ? nil : place,
                    personIDs: people[id] ?? [],
                    petIDs: pets[id] ?? [],
                    labels: labels[id] ?? []
                )
            }
        }
    }

    public func understandingStamps() throws -> [UnderstandingStamp] {
        try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT asset.id AS id, asset.mediaKind AS mediaKind, asset.contentHash AS contentHash,
                       asset.fileSize AS fileSize, asset.fileMTime AS fileMTime,
                       understanding_scan.contentToken AS scannedToken
                FROM asset
                LEFT JOIN understanding_scan ON understanding_scan.assetID = asset.id
                """
            )
            return rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                let kind = MediaKind(rawValue: row["mediaKind"] ?? "") ?? .photo
                let hash: String? = row["contentHash"]
                let size: Int64? = row["fileSize"]
                let mtime: Double? = row["fileMTime"]
                return UnderstandingStamp(
                    assetID: id,
                    mediaKind: kind,
                    contentToken: ContentToken.make(
                        contentHash: hash,
                        fileSize: size,
                        modifiedAt: mtime.map { Date(timeIntervalSince1970: $0) }
                    ),
                    scannedToken: row["scannedToken"]
                )
            }
        }
    }

    private static func fetchAssets(_ database: Database, ids: [String]) throws -> [String: Asset] {
        var found: [String: Asset] = [:]
        let chunk = 200
        var index = 0
        while index < ids.count {
            let end = min(index + chunk, ids.count)
            let slice = Array(ids[index..<end])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let assets = try Asset.fetchAll(
                database,
                sql: "SELECT * FROM asset WHERE id IN (\(placeholders))",
                arguments: StatementArguments(slice)
            )
            for asset in assets {
                found[asset.id] = asset
            }
            index = end
        }
        return found
    }

    private static func loadSamples(_ database: Database) throws -> [SubjectSample] {
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT id, assetID, kind, vector FROM subject_sample ORDER BY id"
        )
        return rows.compactMap { row in
            guard let id: String = row["id"],
                  let assetID: String = row["assetID"],
                  let kind = SubjectKind(rawValue: row["kind"] ?? ""),
                  let blob: Data = row["vector"],
                  let vector = VectorBlob.unpack(blob),
                  !vector.isEmpty else { return nil }
            return SubjectSample(id: id, assetID: assetID, kind: kind, vector: vector)
        }
    }

    private static func loadClusters(_ database: Database) throws -> [SubjectCluster] {
        let rows = try Row.fetchAll(database, sql: "SELECT id, kind, name FROM subject_cluster")
        var clusters: [SubjectCluster] = []
        for row in rows {
            guard let id: String = row["id"], let kind = SubjectKind(rawValue: row["kind"] ?? "") else { continue }
            let members = try String.fetchAll(
                database,
                sql: "SELECT sampleID FROM subject_member WHERE clusterID = ? ORDER BY sampleID",
                arguments: [id]
            )
            let rejected = try String.fetchAll(
                database,
                sql: "SELECT assetID FROM subject_rejection WHERE clusterID = ? ORDER BY assetID",
                arguments: [id]
            )
            clusters.append(SubjectCluster(
                id: id,
                kind: kind,
                name: row["name"] ?? "",
                memberIDs: members,
                rejectedAssetIDs: rejected
            ))
        }
        return clusters
    }

    private static func writeClusters(_ database: Database, clusters: [SubjectCluster], samples: [SubjectSample]) throws {
        let assetBySample = Dictionary(samples.map { ($0.id, $0.assetID) }, uniquingKeysWith: { first, _ in first })
        try database.execute(sql: "DELETE FROM subject_member")
        try database.execute(sql: "DELETE FROM subject_rejection")
        try database.execute(sql: "DELETE FROM subject_cluster")
        for cluster in clusters where !cluster.memberIDs.isEmpty {
            try database.execute(
                sql: "INSERT INTO subject_cluster (id, kind, name) VALUES (?, ?, ?)",
                arguments: [cluster.id, cluster.kind.rawValue, cluster.name]
            )
            for sampleID in cluster.memberIDs {
                guard let assetID = assetBySample[sampleID] else { continue }
                try database.execute(
                    sql: "INSERT INTO subject_member (sampleID, clusterID, assetID) VALUES (?, ?, ?)",
                    arguments: [sampleID, cluster.id, assetID]
                )
            }
            for assetID in cluster.rejectedAssetIDs {
                try database.execute(
                    sql: "INSERT OR IGNORE INTO subject_rejection (clusterID, assetID) VALUES (?, ?)",
                    arguments: [cluster.id, assetID]
                )
            }
        }
    }
}
