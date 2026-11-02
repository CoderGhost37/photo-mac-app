import Foundation
import GRDB

enum SearchSchema {
    static let statements: [String] = [
        "ALTER TABLE asset ADD COLUMN placeName TEXT",
        """
        CREATE TABLE text_hit (
          id INTEGER PRIMARY KEY,
          assetID TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
          text TEXT NOT NULL,
          boxX REAL NOT NULL,
          boxY REAL NOT NULL,
          boxWidth REAL NOT NULL,
          boxHeight REAL NOT NULL,
          confidence REAL NOT NULL
        )
        """,
        "CREATE INDEX text_hit_asset ON text_hit(assetID)",
        """
        CREATE VIRTUAL TABLE text_hit_fts USING fts5(
          text,
          content='text_hit',
          content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE TRIGGER text_hit_ai AFTER INSERT ON text_hit BEGIN
          INSERT INTO text_hit_fts(rowid, text) VALUES (new.id, new.text);
        END
        """,
        """
        CREATE TRIGGER text_hit_ad AFTER DELETE ON text_hit BEGIN
          INSERT INTO text_hit_fts(text_hit_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END
        """,
        """
        CREATE TRIGGER text_hit_au AFTER UPDATE ON text_hit BEGIN
          INSERT INTO text_hit_fts(text_hit_fts, rowid, text) VALUES ('delete', old.id, old.text);
          INSERT INTO text_hit_fts(rowid, text) VALUES (new.id, new.text);
        END
        """,
        """
        CREATE TABLE text_scan (
          assetID TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
          contentToken TEXT NOT NULL,
          recognizedAt REAL NOT NULL,
          hitCount INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE asset_keyword (
          assetID TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
          filename TEXT NOT NULL,
          place TEXT NOT NULL,
          dateText TEXT NOT NULL
        )
        """,
        """
        CREATE VIRTUAL TABLE asset_keyword_fts USING fts5(
          filename,
          place,
          dateText,
          content='asset_keyword',
          content_rowid='rowid',
          tokenize='unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE TRIGGER asset_keyword_ai AFTER INSERT ON asset_keyword BEGIN
          INSERT INTO asset_keyword_fts(rowid, filename, place, dateText)
          VALUES (new.rowid, new.filename, new.place, new.dateText);
        END
        """,
        """
        CREATE TRIGGER asset_keyword_ad AFTER DELETE ON asset_keyword BEGIN
          INSERT INTO asset_keyword_fts(asset_keyword_fts, rowid, filename, place, dateText)
          VALUES ('delete', old.rowid, old.filename, old.place, old.dateText);
        END
        """,
        """
        CREATE TRIGGER asset_keyword_au AFTER UPDATE ON asset_keyword BEGIN
          INSERT INTO asset_keyword_fts(asset_keyword_fts, rowid, filename, place, dateText)
          VALUES ('delete', old.rowid, old.filename, old.place, old.dateText);
          INSERT INTO asset_keyword_fts(rowid, filename, place, dateText)
          VALUES (new.rowid, new.filename, new.place, new.dateText);
        END
        """,
        """
        CREATE TABLE embedding (
          assetID TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
          modelID TEXT NOT NULL,
          dimension INTEGER NOT NULL,
          vector BLOB NOT NULL,
          contentToken TEXT NOT NULL,
          embeddedAt REAL NOT NULL
        )
        """
    ]
}

private struct TokenMatches {
    var ocr: [String: Double] = [:]
    var filename = Set<String>()
    var place = Set<String>()
    var dateWords = Set<String>()

    var any: Set<String> {
        Set(ocr.keys).union(filename).union(place).union(dateWords)
    }
}

extension IndexDatabase {
    public func replaceTextHits(
        assetID: String,
        contentToken: String,
        observations: [TextObservation],
        recognizedAt: Date = Date()
    ) throws {
        try db.write { database in
            try database.execute(sql: "DELETE FROM text_hit WHERE assetID = ?", arguments: [assetID])
            var stored = 0
            for observation in observations {
                let text = observation.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let confidence = min(1, max(0, observation.confidence))
                try database.execute(
                    sql: """
                    INSERT INTO text_hit (assetID, text, boxX, boxY, boxWidth, boxHeight, confidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        assetID, text, observation.box.x, observation.box.y,
                        observation.box.width, observation.box.height, confidence
                    ]
                )
                stored += 1
            }
            try database.execute(
                sql: """
                INSERT INTO text_scan (assetID, contentToken, recognizedAt, hitCount)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(assetID) DO UPDATE SET
                  contentToken = excluded.contentToken,
                  recognizedAt = excluded.recognizedAt,
                  hitCount = excluded.hitCount
                """,
                arguments: [assetID, contentToken, recognizedAt.timeIntervalSince1970, stored]
            )
        }
    }

    public func textHits(assetID: String) throws -> [TextHit] {
        try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, assetID, text, boxX, boxY, boxWidth, boxHeight, confidence
                FROM text_hit WHERE assetID = ? ORDER BY id
                """,
                arguments: [assetID]
            )
            return rows.compactMap(Self.textHit)
        }
    }

    public func saveEmbedding(
        assetID: String,
        modelID: String,
        values: [Float],
        contentToken: String,
        embeddedAt: Date = Date()
    ) throws {
        guard !values.isEmpty else { return }
        let blob = VectorBlob.pack(values)
        try db.write { database in
            try database.execute(
                sql: """
                INSERT INTO embedding (assetID, modelID, dimension, vector, contentToken, embeddedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(assetID) DO UPDATE SET
                  modelID = excluded.modelID,
                  dimension = excluded.dimension,
                  vector = excluded.vector,
                  contentToken = excluded.contentToken,
                  embeddedAt = excluded.embeddedAt
                """,
                arguments: [assetID, modelID, values.count, blob, contentToken, embeddedAt.timeIntervalSince1970]
            )
        }
    }

    public func recognitionStamps() throws -> [RecognitionStamp] {
        try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT asset.id AS id, asset.mediaKind AS mediaKind, asset.contentHash AS contentHash,
                       asset.fileSize AS fileSize, asset.fileMTime AS fileMTime,
                       text_scan.contentToken AS textToken,
                       embedding.contentToken AS embeddingToken,
                       embedding.modelID AS embeddingModelID
                FROM asset
                LEFT JOIN text_scan ON text_scan.assetID = asset.id
                LEFT JOIN embedding ON embedding.assetID = asset.id
                """
            )
            return rows.compactMap(Self.stamp)
        }
    }

    public func searchLibrary(
        plan: SearchPlan,
        scope: LibraryQuery,
        queryVector: [Float]? = nil,
        embeddingModelID: String = ClipModel.id,
        limit: Int = SearchRanker.resultLimit
    ) throws -> [RankedAsset] {
        guard plan.isActive, !plan.matchesNothing, limit > 0 else { return [] }
        let evidence = try searchEvidence(plan: plan, scope: scope)
        let textScores = SearchRanker.textScores(evidence)
        var semanticScores: [String: Double] = [:]
        var semanticWeight = 0.0
        if let queryVector, !queryVector.isEmpty {
            let corpus = try embeddings(modelID: embeddingModelID, scope: scope)
            let neighbors = EmbeddingMath.topK(
                query: queryVector,
                corpus: corpus,
                k: min(SearchRanker.semanticNeighbors, max(corpus.count, 1))
            )
            for item in neighbors {
                let unit = SearchRanker.semanticUnit(cosine: item.cosine)
                if unit > 0 {
                    semanticScores[item.id] = unit
                }
            }
            semanticWeight = SearchRanker.defaultSemanticWeight
        }
        let ranked = SearchRanker.rank(
            textScores: textScores,
            semanticScores: semanticScores,
            textWeight: SearchRanker.defaultTextWeight,
            semanticWeight: semanticWeight,
            limit: limit
        )
        guard !ranked.isEmpty else { return [] }
        let assets = try assetsByID(ranked.map(\.assetID))
        return ranked.compactMap { score in
            guard let asset = assets[score.assetID] else { return nil }
            return RankedAsset(
                asset: asset,
                textScore: score.textScore,
                semanticScore: score.semanticScore,
                score: score.score
            )
        }
    }

    func backfillSearchKeywords() throws {
        try db.write { database in
            let assets = try Asset.fetchAll(
                database,
                sql: """
                SELECT asset.* FROM asset
                WHERE NOT EXISTS (
                  SELECT 1 FROM asset_keyword WHERE asset_keyword.assetID = asset.id
                )
                """
            )
            for asset in assets {
                try upsertKeyword(database, asset: asset)
            }
        }
    }

    func upsertKeyword(_ database: Database, asset: Asset) throws {
        try database.execute(sql: "DELETE FROM asset_keyword WHERE assetID = ?", arguments: [asset.id])
        try database.execute(
            sql: "INSERT INTO asset_keyword (assetID, filename, place, dateText) VALUES (?, ?, ?, ?)",
            arguments: [
                asset.id,
                SearchDocument.filename(path: asset.filePath),
                asset.placeName ?? "",
                SearchDocument.dateText(for: asset.createdAt, calendar: .current)
            ]
        )
    }

    func deleteSearchRows(_ database: Database, assetIDs: [String]) throws {
        let chunk = 200
        var index = 0
        while index < assetIDs.count {
            let end = min(index + chunk, assetIDs.count)
            let slice = Array(assetIDs[index..<end])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let arguments = StatementArguments(slice)
            try database.execute(sql: "DELETE FROM text_hit WHERE assetID IN (\(placeholders))", arguments: arguments)
            try database.execute(sql: "DELETE FROM asset_keyword WHERE assetID IN (\(placeholders))", arguments: arguments)
            try database.execute(sql: "DELETE FROM text_scan WHERE assetID IN (\(placeholders))", arguments: arguments)
            try database.execute(sql: "DELETE FROM embedding WHERE assetID IN (\(placeholders))", arguments: arguments)
            index = end
        }
    }

    private func searchEvidence(plan: SearchPlan, scope: LibraryQuery) throws -> [SearchEvidence] {
        guard plan.isActive, !plan.matchesNothing, let scopeSQL = Self.scopeClause(scope) else { return [] }
        return try db.read { database in
            let dated = try Self.creationDates(database, scopeSQL: scopeSQL)
            if plan.tokens.isEmpty {
                return try Self.dateOnlyEvidence(database, plan: plan, scopeSQL: scopeSQL, dated: dated)
            }
            let matches = try plan.tokens.map { token in
                try Self.tokenMatches(database, token: token, scopeSQL: scopeSQL)
            }
            guard var ids = matches.first?.any else { return [] }
            for item in matches.dropFirst() {
                ids.formIntersection(item.any)
            }
            let range = plan.dateRange
            if let range {
                ids = ids.filter { id in
                    guard let created = dated[id] else { return false }
                    return range.contains(created)
                }
            }
            return ids.map { id in
                Self.evidence(id: id, tokens: matches, inRange: range != nil)
            }
        }
    }

    private func embeddings(modelID: String, scope: LibraryQuery) throws -> [EmbeddedAsset] {
        guard let scopeSQL = Self.scopeClause(scope) else { return [] }
        return try db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT embedding.assetID AS assetID, embedding.vector AS vector
                FROM embedding
                JOIN asset ON asset.id = embedding.assetID
                WHERE embedding.modelID = ? AND \(scopeSQL.0)
                """,
                arguments: StatementArguments([modelID]) + scopeSQL.1
            )
            return rows.compactMap { row in
                guard let id: String = row["assetID"],
                      let blob: Data = row["vector"],
                      let values = VectorBlob.unpack(blob),
                      !values.isEmpty else { return nil }
                return EmbeddedAsset(id: id, values: values)
            }
        }
    }

    private func assetsByID(_ ids: [String]) throws -> [String: Asset] {
        guard !ids.isEmpty else { return [:] }
        return try db.read { database in
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
    }

    private static func dateOnlyEvidence(
        _ database: Database,
        plan: SearchPlan,
        scopeSQL: (String, StatementArguments),
        dated: [String: Date]
    ) throws -> [SearchEvidence] {
        var ids = Set<String>()
        if let range = plan.dateRange {
            for (id, created) in dated where range.contains(created) {
                ids.insert(id)
            }
        }
        let matches: [TokenMatches]
        if plan.dateTokens.isEmpty {
            matches = []
        } else {
            matches = try plan.dateTokens.map { try tokenMatches(database, token: $0, scopeSQL: scopeSQL) }
            if var textIDs = matches.first?.any {
                for item in matches.dropFirst() {
                    textIDs.formIntersection(item.any)
                }
                ids.formUnion(textIDs)
            }
        }
        return ids.map { id in
            let inRange = dated[id].map { plan.dateRange?.contains($0) ?? false } ?? false
            let covered = !matches.isEmpty && matches.allSatisfy { $0.any.contains(id) }
            if covered {
                return evidence(id: id, tokens: matches, inRange: inRange)
            }
            return SearchEvidence(assetID: id, inDateRange: inRange)
        }
    }

    private static func evidence(id: String, tokens: [TokenMatches], inRange: Bool) -> SearchEvidence {
        let filename = tokens.allSatisfy { $0.filename.contains(id) }
        let place = tokens.allSatisfy { $0.place.contains(id) }
        let dateWords = tokens.allSatisfy { $0.dateWords.contains(id) }
        let ocrComplete = tokens.allSatisfy { $0.ocr[id] != nil }
        let ocr = tokens.reduce(0.0) { $0 + ($1.ocr[id] ?? 0) }
        return SearchEvidence(
            assetID: id,
            ocr: ocr,
            filename: filename,
            place: place,
            dateWords: dateWords,
            inDateRange: inRange,
            combinedFields: !filename && !place && !dateWords && !ocrComplete
        )
    }

    private static func tokenMatches(
        _ database: Database,
        token: String,
        scopeSQL: (String, StatementArguments)
    ) throws -> TokenMatches {
        var matches = TokenMatches()
        if let expression = FTSQuery.expression(matching: [token]) {
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT text_hit.assetID AS assetID, -bm25(text_hit_fts) AS score
                FROM text_hit_fts
                JOIN text_hit ON text_hit.id = text_hit_fts.rowid
                JOIN asset ON asset.id = text_hit.assetID
                WHERE text_hit_fts MATCH ? AND \(scopeSQL.0)
                """,
                arguments: StatementArguments([expression]) + scopeSQL.1
            )
            var totals: [String: Double] = [:]
            for row in rows {
                if let id: String = row["assetID"] {
                    let score: Double = row["score"] ?? 0
                    totals[id, default: 0] += score
                }
            }
            for (id, score) in totals {
                matches.ocr[id] = score > 0 ? score : 0.0001
            }
        }
        matches.filename = try columnIDs(database, token: token, column: "filename", scopeSQL: scopeSQL)
        matches.place = try columnIDs(database, token: token, column: "place", scopeSQL: scopeSQL)
        matches.dateWords = try columnIDs(database, token: token, column: "dateText", scopeSQL: scopeSQL)
        return matches
    }

    private static func columnIDs(
        _ database: Database,
        token: String,
        column: String,
        scopeSQL: (String, StatementArguments)
    ) throws -> Set<String> {
        guard let match = FTSQuery.column(column, token: token) else { return [] }
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT asset_keyword.assetID AS assetID
            FROM asset_keyword_fts
            JOIN asset_keyword ON asset_keyword.rowid = asset_keyword_fts.rowid
            JOIN asset ON asset.id = asset_keyword.assetID
            WHERE asset_keyword_fts MATCH ? AND \(scopeSQL.0)
            """,
            arguments: StatementArguments([match]) + scopeSQL.1
        )
        var ids = Set<String>()
        for row in rows {
            if let id: String = row["assetID"] {
                ids.insert(id)
            }
        }
        return ids
    }

    private static func creationDates(
        _ database: Database,
        scopeSQL: (String, StatementArguments)
    ) throws -> [String: Date] {
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT asset.id AS id, asset.createdAt AS createdAt FROM asset WHERE \(scopeSQL.0)",
            arguments: scopeSQL.1
        )
        var dates: [String: Date] = [:]
        for row in rows {
            if let id: String = row["id"], let stamp: Double = row["createdAt"] {
                dates[id] = Date(timeIntervalSince1970: stamp)
            }
        }
        return dates
    }

    private static func scopeClause(_ query: LibraryQuery) -> (String, StatementArguments)? {
        guard !query.sourceIDs.isEmpty else { return nil }
        let placeholders = Array(repeating: "?", count: query.sourceIDs.count).joined(separator: ",")
        let sql = "asset.sourceID IN (\(placeholders)) AND asset.mediaKind = COALESCE(?, asset.mediaKind)"
        let arguments = StatementArguments(query.sourceIDs) + StatementArguments([query.mediaKind?.rawValue])
        return (sql, arguments)
    }

    private static func textHit(_ row: Row) -> TextHit? {
        guard let id: Int64 = row["id"], let assetID: String = row["assetID"], let text: String = row["text"] else {
            return nil
        }
        let boxX: Double = row["boxX"] ?? 0
        let boxY: Double = row["boxY"] ?? 0
        let boxWidth: Double = row["boxWidth"] ?? 0
        let boxHeight: Double = row["boxHeight"] ?? 0
        let confidence: Double = row["confidence"] ?? 0
        return TextHit(
            id: id,
            assetID: assetID,
            text: text,
            box: NormalizedBox(x: boxX, y: boxY, width: boxWidth, height: boxHeight),
            confidence: confidence
        )
    }

    private static func stamp(_ row: Row) -> RecognitionStamp? {
        guard let id: String = row["id"] else { return nil }
        let kind = MediaKind(rawValue: row["mediaKind"] ?? "") ?? .photo
        let hash: String? = row["contentHash"]
        let size: Int64? = row["fileSize"]
        let mtime: Double? = row["fileMTime"]
        return RecognitionStamp(
            assetID: id,
            mediaKind: kind,
            contentToken: ContentToken.make(
                contentHash: hash,
                fileSize: size,
                modifiedAt: mtime.map { Date(timeIntervalSince1970: $0) }
            ),
            textToken: row["textToken"],
            embeddingToken: row["embeddingToken"],
            embeddingModelID: row["embeddingModelID"]
        )
    }
}
