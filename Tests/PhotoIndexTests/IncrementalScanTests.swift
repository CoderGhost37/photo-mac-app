import XCTest
@testable import PhotoIndex

final class IncrementalScanTests: XCTestCase {
    func testNewFilesAreIndexedAndUnchangedFilesAreSkipped() async throws {
        let harness = try ScanHarness()
        defer { harness.cleanup() }
        try harness.write("one.jpg", FixtureImages.jpeg(), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try harness.write("notes.txt", Data("ignore".utf8), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try harness.write("clip.mov", FixtureImages.movie(width: 64, height: 48, timescale: 600, duration: 1200), modifiedAt: Date(timeIntervalSince1970: 1_700_000_100))

        let first = try await harness.scan()
        XCTAssertEqual(first.inserted, 2)
        XCTAssertEqual(first.updated, 0)
        XCTAssertEqual(first.deleted, 0)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(harness.reader.calls, 2)

        let indexed = try harness.database.assets(sourceID: harness.source.id)
        XCTAssertEqual(Set(indexed.map(\.mediaKind)), [.photo, .video])
        let photo = try XCTUnwrap(indexed.first { $0.filePath?.hasSuffix("one.jpg") == true })
        XCTAssertEqual(photo.pixelWidth, 80)
        XCTAssertEqual(photo.pixelHeight, 120)
        XCTAssertEqual(photo.cameraMake, "Canon")
        XCTAssertEqual(photo.latitude ?? 0, 37.8, accuracy: 0.0001)
        XCTAssertFalse(photo.contentHash?.isEmpty ?? true)

        let second = try await harness.scan()
        XCTAssertEqual(second, ScanStats(inserted: 0, updated: 0, deleted: 0, skipped: 2))
        XCTAssertEqual(harness.reader.calls, 2)
        XCTAssertEqual(harness.hasher.calls, 2)
    }

    func testChangedFileIsReindexedAndKeepsItsID() async throws {
        let harness = try ScanHarness()
        defer { harness.cleanup() }
        let original = Data(repeating: 0x11, count: 32)
        try harness.write("shot.png", original, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await harness.scan()
        let before = try XCTUnwrap(try harness.database.assets(sourceID: harness.source.id).first)
        let callsAfterFirst = harness.reader.calls

        var changed = original
        changed[0] = 0x22
        try harness.write("shot.png", changed, modifiedAt: Date(timeIntervalSince1970: 1_700_000_050))
        let stats = try await harness.scan()
        XCTAssertEqual(stats.inserted, 0)
        XCTAssertEqual(stats.updated, 1)
        XCTAssertEqual(stats.skipped, 0)
        XCTAssertEqual(harness.reader.calls, callsAfterFirst + 1)

        let after = try XCTUnwrap(try harness.database.assets(sourceID: harness.source.id).first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertNotEqual(after.contentHash, before.contentHash)
        XCTAssertEqual(try harness.database.assets(sourceID: harness.source.id).count, 1)
    }

    func testDeletedFileLeavesTheIndex() async throws {
        let harness = try ScanHarness()
        defer { harness.cleanup() }
        try harness.write("keep.png", FixtureImages.png(width: 8, height: 8), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try harness.write("gone.png", FixtureImages.png(width: 9, height: 9), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await harness.scan()
        let gone = try XCTUnwrap(try harness.database.assets(sourceID: harness.source.id).first { $0.filePath?.hasSuffix("gone.png") == true })
        try FileManager.default.removeItem(at: harness.root.appendingPathComponent("gone.png"))

        let stats = try await harness.scan()
        XCTAssertEqual(stats.deleted, 1)
        XCTAssertEqual(stats.inserted, 0)
        XCTAssertEqual(stats.updated, 0)
        XCTAssertEqual(stats.skipped, 1)
        let remaining = try harness.database.assets(sourceID: harness.source.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNil(try harness.database.asset(id: gone.id))
        XCTAssertTrue(remaining[0].filePath?.hasSuffix("keep.png") == true)
    }

    func testAddedFileIsInsertedOnTheNextScan() async throws {
        let harness = try ScanHarness()
        defer { harness.cleanup() }
        try harness.write("a.png", FixtureImages.png(width: 4, height: 4), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await harness.scan()
        try harness.write("b.png", FixtureImages.png(width: 5, height: 6), modifiedAt: Date(timeIntervalSince1970: 1_700_000_010))
        let stats = try await harness.scan()
        XCTAssertEqual(stats.inserted, 1)
        XCTAssertEqual(stats.skipped, 1)
        XCTAssertEqual(try harness.database.assets(sourceID: harness.source.id).count, 2)
    }

    func testScreenshotAndRecordingSourcesShareAFolderButNotFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try IndexDatabase.inMemory()
        let shots = Source(id: Source.screenshotsID, kind: .screenshots, displayName: "Screenshots", rootPath: root.path, bookmarkData: nil, enabled: true, lastScanAt: nil)
        let recordings = Source(id: Source.screenRecordingsID, kind: .screenRecordings, displayName: "Screen Recordings", rootPath: root.path, bookmarkData: nil, enabled: true, lastScanAt: nil)
        try database.save(source: shots)
        try database.save(source: recordings)
        try Data(FixtureImages.png(width: 2, height: 2)).write(to: root.appendingPathComponent("Screen Shot.png"))
        try FixtureImages.movie(width: 16, height: 16, timescale: 1, duration: 2).write(to: root.appendingPathComponent("Screen Recording.mov"))
        let indexer = Indexer(database: database, metadataReader: PortableMetadataReader())
        _ = try await indexer.scan(shots)
        _ = try await indexer.scan(recordings)
        let shotAssets = try database.assets(sourceID: shots.id)
        let recordingAssets = try database.assets(sourceID: recordings.id)
        XCTAssertEqual(shotAssets.map(\.mediaKind), [.screenshot])
        XCTAssertEqual(recordingAssets.map(\.mediaKind), [.screenRecording])
    }

    func testMissingFolderDoesNotDeleteIndexedFiles() async throws {
        let harness = try ScanHarness()
        defer { harness.cleanup() }
        try harness.write("a.png", FixtureImages.png(width: 2, height: 2), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await harness.scan()
        try FileManager.default.removeItem(at: harness.root)
        var missing = harness.source
        missing.rootPath = harness.root.path
        do {
            _ = try await harness.indexer.scan(missing)
            XCTFail("expected a missing folder to throw")
        } catch IndexError.sourceRootMissing {
            let remaining = try harness.database.assets(sourceID: harness.source.id)
            XCTAssertEqual(remaining.count, 1)
        }
    }
}

final class SpyReader: MetadataReading, @unchecked Sendable {
    private(set) var calls = 0
    private let inner = PortableMetadataReader()

    func metadata(forFileAt url: URL) async -> ExtractedMetadata {
        calls += 1
        return inner.metadataSync(forFileAt: url)
    }
}

final class SpyHasher: ContentHashing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private let inner = SHA256FileHasher()

    func hash(ofFileAt url: URL) throws -> String {
        lock.lock()
        calls += 1
        lock.unlock()
        return try inner.hash(ofFileAt: url)
    }
}

struct ScanHarness {
    let root: URL
    let database: IndexDatabase
    let source: Source
    let reader: SpyReader
    let hasher: SpyHasher
    let indexer: Indexer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try IndexDatabase.inMemory()
        source = Source(
            id: "folder.desk",
            kind: .folder,
            displayName: "Desk",
            rootPath: root.path,
            bookmarkData: nil,
            enabled: true,
            lastScanAt: nil
        )
        try database.save(source: source)
        reader = SpyReader()
        hasher = SpyHasher()
        indexer = Indexer(database: database, metadataReader: reader, hasher: hasher)
    }

    func write(_ name: String, _ data: Data, modifiedAt: Date) throws {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    func scan() async throws -> ScanStats {
        try await indexer.scan(source)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
