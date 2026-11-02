import XCTest
@testable import PhotoIndex

final class SearchTests: XCTestCase {
    func testFTSFindsTextAcrossLinesAndIgnoresAPartialAsset() throws {
        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        try database.applyChanges(inserted: [
            photo(id: "both", path: "/desk/both.jpg"),
            photo(id: "one", path: "/desk/one.jpg")
        ], updated: [], deletedIDs: [])
        try database.replaceTextHits(assetID: "both", contentToken: "h:both", observations: [
            observation("invoice", y: 0.2),
            observation("total", y: 0.6)
        ])
        try database.replaceTextHits(assetID: "one", contentToken: "h:one", observations: [
            observation("invoice", y: 0.2)
        ])

        let plan = SearchPlan.parse("\"invoice\" total")
        let found = try database.searchLibrary(plan: plan, scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertEqual(found.map(\.asset.id), ["both"])
        let hits = try database.textHits(assetID: "both")
        XCTAssertEqual(hits.map(\.text), ["invoice", "total"])
        XCTAssertEqual(hits[0].box.y, 0.2)
        XCTAssertTrue(TextHighlight.matches(text: hits[0].text, tokens: plan.highlightTokens))
    }

    func testFilenamePlaceAndDateSearch() throws {
        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        let june = localDate(year: 2024, month: 6, day: 15)
        let may = localDate(year: 2020, month: 5, day: 2)
        try database.applyChanges(inserted: [
            photo(id: "named", path: "/desk/holiday-cat.JPG", created: may),
            photo(id: "lisbon", path: "/desk/img.jpg", created: may, place: "Lisbon, Portugal"),
            photo(id: "june", path: "/desk/plain.jpg", created: june),
            photo(id: "video", path: "/desk/clip.mov", created: june, kind: .video)
        ], updated: [], deletedIDs: [])

        let named = try database.searchLibrary(plan: SearchPlan.parse("holiday"), scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertEqual(named.map(\.asset.id), ["named"])

        let place = try database.searchLibrary(plan: SearchPlan.parse("lisbon"), scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertEqual(place.map(\.asset.id), ["lisbon"])

        let dated = try database.searchLibrary(plan: SearchPlan.parse("june 2024"), scope: LibraryQuery(sourceIDs: ["desk"], mediaKind: .photo))
        XCTAssertEqual(dated.map(\.asset.id), ["june"])

        let namedByYear = try database.searchLibrary(plan: SearchPlan.parse("2020"), scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertTrue(namedByYear.map(\.asset.id).contains("named"))
        XCTAssertTrue(namedByYear.map(\.asset.id).contains("lisbon"))
        XCTAssertFalse(namedByYear.map(\.asset.id).contains("june"))
    }

    func testDescriptionRankingBlendsWithTextMatches() throws {
        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        try database.applyChanges(inserted: [
            photo(id: "text", path: "/desk/text.jpg"),
            photo(id: "near", path: "/desk/near.jpg")
        ], updated: [], deletedIDs: [])
        try database.replaceTextHits(assetID: "text", contentToken: "h:text", observations: [observation("cat")])
        try database.saveEmbedding(assetID: "text", modelID: "test-model", values: [0, 1], contentToken: "h:text")
        try database.saveEmbedding(assetID: "near", modelID: "test-model", values: [1, 0], contentToken: "h:near")

        let blended = try database.searchLibrary(
            plan: SearchPlan.parse("cat"),
            scope: LibraryQuery(sourceIDs: ["desk"]),
            queryVector: [1, 0],
            embeddingModelID: "test-model"
        )
        XCTAssertEqual(blended.map(\.asset.id), ["text", "near"])
        XCTAssertEqual(blended[0].textScore, 1, accuracy: 0.0001)
        XCTAssertEqual(blended[0].semanticScore, 0, accuracy: 0.0001)
        XCTAssertEqual(blended[0].score, 0.6, accuracy: 0.0001)
        XCTAssertEqual(blended[1].textScore, 0, accuracy: 0.0001)
        XCTAssertEqual(blended[1].semanticScore, 1, accuracy: 0.0001)
        XCTAssertEqual(blended[1].score, 0.4, accuracy: 0.0001)

        let described = try database.searchLibrary(
            plan: SearchPlan.parse("a red bicycle"),
            scope: LibraryQuery(sourceIDs: ["desk"]),
            queryVector: [1, 0],
            embeddingModelID: "test-model"
        )
        XCTAssertEqual(described.map(\.asset.id), ["near"])
    }

    func testDeletingASourceDropsItsText() throws {
        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        try database.applyChanges(inserted: [photo(id: "gone", path: "/desk/gone.jpg")], updated: [], deletedIDs: [])
        try database.replaceTextHits(assetID: "gone", contentToken: "h:gone", observations: [observation("receipt")])
        try database.deleteSource(id: "desk")
        XCTAssertTrue(try database.textHits(assetID: "gone").isEmpty)
        let source = Source(id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk", bookmarkData: nil, enabled: true, lastScanAt: nil)
        try database.save(source: source)
        let found = try database.searchLibrary(plan: SearchPlan.parse("receipt"), scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertTrue(found.isEmpty)
    }

    func testOCRSelectionIsIncrementalAndSkipsVideoUnlessAsked() throws {
        let photoStamp = RecognitionStamp(assetID: "p", mediaKind: .photo, contentToken: "h:1")
        let done = RecognitionStamp(
            assetID: "d",
            mediaKind: .photo,
            contentToken: "h:1",
            textToken: "h:1",
            embeddingToken: "h:1",
            embeddingModelID: ClipModel.id
        )
        let changed = RecognitionStamp(assetID: "c", mediaKind: .screenshot, contentToken: "h:2", textToken: "h:1")
        let video = RecognitionStamp(assetID: "v", mediaKind: .video, contentToken: "h:3")
        let recording = RecognitionStamp(assetID: "r", mediaKind: .screenRecording, contentToken: "h:4")
        let stamps = [video, photoStamp, done, changed, recording]
        XCTAssertEqual(RecognitionPlan.needsTextRecognition(stamps, includeVideoKeyframes: false), ["c", "p"])
        XCTAssertEqual(RecognitionPlan.needsTextRecognition(stamps, includeVideoKeyframes: true), ["c", "p", "r", "v"])
        XCTAssertEqual(RecognitionPlan.needsEmbedding(stamps, modelID: ClipModel.id, includeVideoKeyframes: false), ["c", "p"])
        XCTAssertEqual(ContentToken.make(contentHash: "abc", fileSize: 1, modifiedAt: nil), "h:abc")
        XCTAssertEqual(ContentToken.make(contentHash: "  ", fileSize: 4, modifiedAt: nil), "t:4:none")

        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        try database.applyChanges(inserted: [
            photo(id: "still", path: "/desk/still.jpg", hash: "aaa"),
            photo(id: "clip", path: "/desk/clip.mov", kind: .video, hash: "bbb")
        ], updated: [], deletedIDs: [])
        var pending = try database.recognitionStamps()
        XCTAssertEqual(RecognitionPlan.needsTextRecognition(pending, includeVideoKeyframes: false), ["still"])
        let still = try XCTUnwrap(pending.first { $0.assetID == "still" })
        try database.replaceTextHits(assetID: "still", contentToken: still.contentToken, observations: [])
        try database.saveEmbedding(assetID: "still", modelID: ClipModel.id, values: [1, 0], contentToken: still.contentToken)
        pending = try database.recognitionStamps()
        XCTAssertTrue(RecognitionPlan.needsTextRecognition(pending, includeVideoKeyframes: false).isEmpty)
        XCTAssertTrue(RecognitionPlan.needsEmbedding(pending, modelID: ClipModel.id, includeVideoKeyframes: false).isEmpty)

        var updated = try XCTUnwrap(try database.asset(id: "still"))
        updated.contentHash = "changed"
        try database.applyChanges(inserted: [], updated: [updated], deletedIDs: [])
        pending = try database.recognitionStamps()
        XCTAssertEqual(RecognitionPlan.needsTextRecognition(pending, includeVideoKeyframes: false), ["still"])
        XCTAssertEqual(RecognitionPlan.needsEmbedding(pending, modelID: ClipModel.id, includeVideoKeyframes: false), ["still"])
    }

    func testQueryBuilderDatesAndRankingMath() throws {
        XCTAssertEqual(FTSQuery.expression(matching: ["hello", "world"]), "\"hello\"* AND \"world\"*")
        XCTAssertEqual(FTSQuery.expression(matching: ["and"]), "\"and\"*")
        XCTAssertNil(FTSQuery.expression(matching: []))
        XCTAssertEqual(SearchPlan.parse("Hello, \"World\"!").tokens, ["hello", "world"])
        XCTAssertFalse(SearchPlan.parse("   ").isActive)
        XCTAssertEqual(SearchPlan.parse("may").tokens, ["may"])
        XCTAssertNil(SearchPlan.parse("may").dateRange)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 15)))
        let mixed = SearchPlan.parse("beach june 2024", now: now, calendar: calendar)
        XCTAssertEqual(mixed.tokens, ["beach"])
        XCTAssertEqual(mixed.dateTokens, ["june", "2024"])
        let june = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 6, day: 1)))
        XCTAssertEqual(mixed.dateRange?.start, june)
        XCTAssertTrue(SearchPlan.parse("june 2024 may 2024", now: now, calendar: calendar).matchesNothing)
        let today = SearchPlan.parse("today", now: now, calendar: calendar)
        XCTAssertEqual(today.dateRange?.start, calendar.startOfDay(for: now))
        XCTAssertTrue(today.tokens.isEmpty)

        let scores = SearchRanker.textScores([
            SearchEvidence(assetID: "ocr", ocr: 4),
            SearchEvidence(assetID: "file", filename: true),
            SearchEvidence(assetID: "split", combinedFields: true)
        ])
        XCTAssertEqual(scores["ocr"], 1)
        XCTAssertEqual(scores["file"], 0.92)
        XCTAssertEqual(scores["split"], 0.64)
        let ranked = SearchRanker.rank(
            textScores: ["a": 1, "b": 0.5],
            semanticScores: ["b": 1, "c": 1],
            textWeight: 0.6,
            semanticWeight: 0.4,
            limit: 10
        )
        XCTAssertEqual(ranked.map(\.assetID), ["b", "a", "c"])
        XCTAssertEqual(ranked[0].score, 0.7, accuracy: 0.0001)
        XCTAssertEqual(ranked[1].score, 0.6, accuracy: 0.0001)
        XCTAssertEqual(ranked[2].score, 0.4, accuracy: 0.0001)
        XCTAssertEqual(SearchRanker.semanticUnit(cosine: 0.15), 0)
        XCTAssertEqual(SearchRanker.semanticUnit(cosine: 1), 1)
        XCTAssertEqual(SearchRanker.semanticUnit(cosine: 0.575), 0.5, accuracy: 0.0001)
        XCTAssertTrue(SearchRanker.rank(textScores: ["a": 1], semanticScores: [:], limit: 0).isEmpty)

        let box = NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(box.flippedVertically(), NormalizedBox(x: 0.1, y: 0.4, width: 0.3, height: 0.4))
        XCTAssertEqual(NormalizedBox(x: -0.2, y: 0.8, width: 0.5, height: 0.5).clamped().width, 0.5, accuracy: 0.0001)
        XCTAssertTrue(TextHighlight.matches(text: "Receipt total", tokens: ["rece"]))
        XCTAssertFalse(TextHighlight.matches(text: "Receipt", tokens: []))
    }
}

final class EmbeddingTests: XCTestCase {
    func testCosineTopKOrdersTiesAndRejectsBadVectors() {
        let corpus = [
            EmbeddedAsset(id: "b", values: [1, 0]),
            EmbeddedAsset(id: "a", values: [1, 0]),
            EmbeddedAsset(id: "c", values: [0, 1]),
            EmbeddedAsset(id: "z", values: [0, 0]),
            EmbeddedAsset(id: "short", values: [1])
        ]
        let top = EmbeddingMath.topK(query: [1, 0], corpus: corpus, k: 2)
        XCTAssertEqual(top.map(\.id), ["a", "b"])
        XCTAssertEqual(top[0].cosine, 1, accuracy: 0.0001)
        XCTAssertEqual(EmbeddingMath.topK(query: [1, 0], corpus: corpus, k: 3).map(\.id), ["a", "b", "c"])
        XCTAssertTrue(EmbeddingMath.topK(query: [1, 0], corpus: corpus, k: 0).isEmpty)
        XCTAssertEqual(EmbeddingMath.cosine([1, 0], [0, 0]), 0)
        XCTAssertEqual(EmbeddingMath.cosine([1], [1, 0]), 0)
        XCTAssertEqual(EmbeddingMath.cosine([1, 0], [-1, 0]), -1, accuracy: 0.0001)
        let pooled = EmbeddingMath.pooledText(
            sequence: [1, 0, 0, 2, 3, 0],
            tokens: [10, 99, 0],
            endOfText: 99,
            dimension: 2
        )
        XCTAssertEqual(pooled ?? [], [0, 1])
        XCTAssertEqual(VectorBlob.unpack(VectorBlob.pack([1.5, -2])), [1.5, -2])
        XCTAssertNil(VectorBlob.unpack(Data([1, 2, 3])))
    }

    func testTokenizerMatchesTheCLIPBytePairRules() {
        let merged = CLIPTokenizer(mergesText: "#version: 0.2\na b</w>\n")
        XCTAssertEqual(merged.startOfText, 513)
        XCTAssertEqual(merged.endOfText, 514)
        XCTAssertEqual(Array(merged.encode("ab").prefix(4)), [513, 512, 514, 0])
        XCTAssertEqual(merged.encode("ab").count, ClipModel.contextLength)
        XCTAssertEqual(Array(merged.encode("AB").prefix(4)), [513, 512, 514, 0])
        XCTAssertEqual(Array(merged.encode("a b").prefix(5)), [513, 320, 321, 514, 0])
        let plain = CLIPTokenizer(mergesText: "#version: 0.2\n")
        XCTAssertEqual(plain.pieceIDs(for: "ab"), [64, 321])
        let truncated = CLIPTokenizer(mergesText: "#version: 0.2\na b</w>\n", contextLength: 2)
        XCTAssertEqual(truncated.encode("ab"), [513, 514])
    }

    func testChecksumManifestAndGeometry() throws {
        let manifest = """
        # comment
        \(SHA256Digest.hex(Data("hello".utf8)))  a.txt
        \(SHA256Digest.hex(Data("world".utf8)))  sub/b.txt
        """
        let parsed = ModelChecksums.parse(manifest)
        XCTAssertEqual(parsed["a.txt"], SHA256Digest.hex(Data("hello".utf8)))
        XCTAssertNil(ModelChecksums.parse("nope").first?.key)
        XCTAssertEqual(ModelChecksums.failures(expected: parsed, actual: parsed), [])
        XCTAssertEqual(ModelChecksums.failures(expected: parsed, actual: ["a.txt": parsed["a.txt"]!]), ["sub/b.txt"])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: directory.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: directory.appendingPathComponent("sub/b.txt"))
        try manifest.write(to: directory.appendingPathComponent("checksums.sha256"), atomically: true, encoding: .utf8)
        let actual = try ModelChecksums.hashTree(directory: directory)
        XCTAssertEqual(ModelChecksums.failures(expected: parsed, actual: actual), [])
        try Data("hello!".utf8).write(to: directory.appendingPathComponent("a.txt"))
        let changed = try ModelChecksums.hashTree(directory: directory)
        XCTAssertEqual(ModelChecksums.failures(expected: parsed, actual: changed), ["a.txt"])

        let fitted = try XCTUnwrap(AspectFit.rect(containerWidth: 100, containerHeight: 100, imageWidth: 200, imageHeight: 100))
        XCTAssertEqual(fitted, FittedRect(x: 0, y: 25, width: 100, height: 50))
        XCTAssertNil(AspectFit.rect(containerWidth: 0, containerHeight: 10, imageWidth: 10, imageHeight: 10))
        XCTAssertEqual(CenterSquare.crop(width: 100, height: 40), PixelRect(x: 30, y: 0, width: 40, height: 40))
        XCTAssertNil(CenterSquare.crop(width: 0, height: 10))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12)))
        let words = SearchDocument.dateText(for: date, calendar: calendar)
        XCTAssertTrue(words.contains("june"))
        XCTAssertTrue(words.contains("2024"))
    }
}

private func saveDesk(_ database: IndexDatabase) throws {
    let source = Source(id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk", bookmarkData: nil, enabled: true, lastScanAt: nil)
    try database.save(source: source)
}

private func photo(
    id: String,
    path: String,
    created: Date? = nil,
    place: String? = nil,
    kind: MediaKind = .photo,
    hash: String? = nil
) -> Asset {
    Asset(
        id: id,
        sourceID: "desk",
        filePath: path,
        photosLocalIdentifier: nil,
        mediaKind: kind,
        createdAt: created,
        modifiedAt: created,
        pixelWidth: 20,
        pixelHeight: 10,
        fileSize: 100,
        duration: kind == .video ? 3 : nil,
        latitude: nil,
        longitude: nil,
        placeName: place,
        contentHash: hash ?? "hash-\(id)",
        fileMTime: created,
        indexedAt: created
    )
}

private func observation(_ text: String, y: Double = 0.1) -> TextObservation {
    TextObservation(text: text, box: NormalizedBox(x: 0.1, y: y, width: 0.4, height: 0.1), confidence: 0.9)
}

private func localDate(year: Int, month: Int, day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    return Calendar.current.date(from: components)!
}
