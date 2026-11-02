import XCTest
@testable import PhotoIndex

final class QueryTests: XCTestCase {
    func testFiltersSortingAndCounts() throws {
        let database = try IndexDatabase.inMemory()
        let desk = Source(id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk", bookmarkData: nil, enabled: true, lastScanAt: nil)
        let downloads = Source(id: "downloads", kind: .downloads, displayName: "Downloads", rootPath: "/downloads", bookmarkData: nil, enabled: false, lastScanAt: nil)
        try database.save(source: desk)
        try database.save(source: downloads)

        try database.applyChanges(inserted: [
            sample(id: "old", source: "desk", kind: .photo, created: date(2020, 1, 2), path: "/desk/old.jpg"),
            sample(id: "new", source: "desk", kind: .photo, created: date(2024, 5, 1), path: "/desk/new.jpg"),
            sample(id: "clip", source: "desk", kind: .video, created: date(2023, 3, 3), path: "/desk/clip.mov"),
            sample(id: "shot", source: "desk", kind: .screenshot, created: nil, path: "/desk/shot.png"),
            sample(id: "down", source: "downloads", kind: .photo, created: date(2022, 2, 2), path: "/downloads/a.jpg")
        ], updated: [], deletedIDs: [])

        let deskPhotos = try database.fetchAssets(
            matching: LibraryQuery(sourceIDs: ["desk"], mediaKind: .photo),
            limit: 50,
            offset: 0
        )
        XCTAssertEqual(deskPhotos.map(\.id), ["new", "old"])

        let deskAll = try database.fetchAssets(
            matching: LibraryQuery(sourceIDs: ["desk"]),
            limit: 50,
            offset: 0
        )
        XCTAssertEqual(deskAll.map(\.id), ["new", "clip", "old", "shot"])
        let unlimited = try database.fetchAssets(matching: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertEqual(unlimited.map(\.id), deskAll.map(\.id))

        let page = try database.fetchAssets(
            matching: LibraryQuery(sourceIDs: ["desk"]),
            limit: 2,
            offset: 1
        )
        XCTAssertEqual(page.map(\.id), ["clip", "old"])

        XCTAssertEqual(try database.countAssets(matching: LibraryQuery(sourceIDs: ["desk"], mediaKind: .video)), 1)
        XCTAssertEqual(try database.countAssets(matching: LibraryQuery(sourceIDs: ["desk", "downloads"], mediaKind: .photo)), 3)
        XCTAssertEqual(try database.countAssets(matching: LibraryQuery(sourceIDs: [])), 0)
        XCTAssertTrue(try database.fetchAssets(matching: LibraryQuery(sourceIDs: []), limit: 10, offset: 0).isEmpty)

        let counts = try database.libraryCounts(enabledSourceIDs: ["desk"])
        XCTAssertEqual(counts.enabledTotal, 4)
        XCTAssertEqual(counts.byMediaKind[.photo], 2)
        XCTAssertEqual(counts.byMediaKind[.video], 1)
        XCTAssertEqual(counts.byMediaKind[.screenshot], 1)
        XCTAssertEqual(counts.bySource["desk"], 4)
        XCTAssertEqual(counts.bySource["downloads"], 1)

        let everything = try database.libraryCounts(enabledSourceIDs: ["desk", "downloads"])
        XCTAssertEqual(everything.enabledTotal, 5)
        XCTAssertEqual(everything.byMediaKind[.photo], 3)
    }

    func testDeletingASourceRemovesItsAssets() throws {
        let database = try IndexDatabase.inMemory()
        let folder = Source(id: "folder.1", kind: .folder, displayName: "Trip", rootPath: "/trip", bookmarkData: Data([1, 2, 3]), enabled: true, lastScanAt: nil)
        try database.save(source: folder)
        try database.applyChanges(inserted: [
            sample(id: "a", source: "folder.1", kind: .photo, created: date(2024, 1, 1), path: "/trip/a.jpg")
        ], updated: [], deletedIDs: [])
        let roundTrip = try XCTUnwrap(try database.source(id: "folder.1"))
        XCTAssertEqual(roundTrip.bookmarkData, Data([1, 2, 3]))
        try database.deleteSource(id: "folder.1")
        XCTAssertNil(try database.source(id: "folder.1"))
        XCTAssertNil(try database.asset(id: "a"))
    }

    func testBuiltinSourceSyncRefreshesPathsWithoutResettingEnabled() throws {
        let database = try IndexDatabase.inMemory()
        let home = URL(fileURLWithPath: "/Users/ada", isDirectory: true)
        let capture = URL(fileURLWithPath: "/Users/ada/Desktop", isDirectory: true)
        _ = try database.synchronizeBuiltinSources(homeDirectory: home, captureDirectory: capture)
        var screenshots = try XCTUnwrap(try database.source(id: Source.screenshotsID))
        screenshots.enabled = false
        screenshots.bookmarkData = Data([9])
        try database.save(source: screenshots)

        let moved = URL(fileURLWithPath: "/Users/ada/Pictures/Shots", isDirectory: true)
        _ = try database.synchronizeBuiltinSources(homeDirectory: home, captureDirectory: moved)
        let updated = try XCTUnwrap(try database.source(id: Source.screenshotsID))
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.bookmarkData, Data([9]))
        XCTAssertEqual(updated.rootPath, "/Users/ada/Pictures/Shots")
        let downloads = try XCTUnwrap(try database.source(id: Source.downloadsID))
        XCTAssertEqual(downloads.rootPath, "/Users/ada/Downloads")
        XCTAssertEqual(try database.sources().count, 4)
    }
}

final class SupportTests: XCTestCase {
    func testScreenshotLocationFallsBackAndExpandsTilde() {
        let home = URL(fileURLWithPath: "/Users/ada", isDirectory: true)
        XCTAssertEqual(ScreenshotLocation.resolve(preferenceValue: nil, home: home).path, "/Users/ada/Desktop")
        XCTAssertEqual(ScreenshotLocation.resolve(preferenceValue: "  ", home: home).path, "/Users/ada/Desktop")
        XCTAssertEqual(ScreenshotLocation.resolve(preferenceValue: "~/Pictures/Shots", home: home).path, "/Users/ada/Pictures/Shots")
        XCTAssertEqual(ScreenshotLocation.resolve(preferenceValue: "/Volumes/Drive/Shots", home: home).path, "/Volumes/Drive/Shots")
    }

    func testIndexLivesInApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/ada", isDirectory: true)
        XCTAssertEqual(
            IndexLocation.databaseURL(home: home).path,
            "/Users/ada/Library/Application Support/Stillroom/index.sqlite"
        )
    }

    func testPhotosLibrarySyncDetectsNewChangedAndDeleted() {
        let kept = photoAsset(id: "photos:1", modified: date(2024, 1, 1), width: 10)
        let changed = photoAsset(id: "photos:2", modified: date(2024, 1, 1), width: 10)
        let removed = photoAsset(id: "photos:3", modified: date(2024, 1, 1), width: 10)
        var edited = changed
        edited.pixelWidth = 20
        edited.modifiedAt = date(2024, 6, 1)
        let added = photoAsset(id: "photos:4", modified: date(2024, 7, 1), width: 30)

        let diff = PhotosLibrarySync.changes(existing: [kept, changed, removed], incoming: [kept, edited, added])
        XCTAssertEqual(diff.inserted.map(\.id), ["photos:4"])
        XCTAssertEqual(diff.updated.map(\.id), ["photos:2"])
        XCTAssertEqual(diff.deletedIDs, ["photos:3"])
        XCTAssertEqual(diff.skipped, 1)
    }

    func testThumbnailCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-thumbs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThumbnailCache(directory: directory)
        XCTAssertNil(cache.existing(assetID: "file:1", maxPixel: 200, token: "abc"))
        let url = try cache.store(Data([1, 2, 3, 4]), assetID: "file:1", maxPixel: 200, token: "abc")
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
        XCTAssertNotNil(cache.existing(assetID: "file:1", maxPixel: 200, token: "abc"))
        XCTAssertNil(cache.existing(assetID: "file:1", maxPixel: 200, token: "changed"))
        try cache.invalidate(assetID: "file:1")
        XCTAssertNil(cache.existing(assetID: "file:1", maxPixel: 200, token: "abc"))
    }

    func testClassifierSplitsCaptureFolderAndNamesDownloads() {
        XCTAssertEqual(MediaClassifier.kind(relativePath: "Screen Shot.png", sourceKind: .screenshots), .screenshot)
        XCTAssertNil(MediaClassifier.kind(relativePath: "Screen Recording.mov", sourceKind: .screenshots))
        XCTAssertEqual(MediaClassifier.kind(relativePath: "Screen Recording.mov", sourceKind: .screenRecordings), .screenRecording)
        XCTAssertNil(MediaClassifier.kind(relativePath: "Screen Shot.png", sourceKind: .screenRecordings))
        XCTAssertEqual(MediaClassifier.kind(relativePath: "holiday/IMG_1.jpg", sourceKind: .downloads), .photo)
        XCTAssertEqual(MediaClassifier.kind(relativePath: "holiday/clip.mp4", sourceKind: .folder), .video)
        XCTAssertEqual(MediaClassifier.kind(relativePath: "Desktop/Screenshot 1.png", sourceKind: .folder), .screenshot)
        XCTAssertNil(MediaClassifier.kind(relativePath: "notes.txt", sourceKind: .downloads))
    }
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func sample(id: String, source: String, kind: MediaKind, created: Date?, path: String) -> Asset {
    Asset(
        id: id,
        sourceID: source,
        filePath: path,
        photosLocalIdentifier: nil,
        mediaKind: kind,
        createdAt: created,
        modifiedAt: created,
        pixelWidth: 10,
        pixelHeight: 10,
        fileSize: 100,
        duration: kind == .video ? 3 : nil,
        latitude: nil,
        longitude: nil,
        contentHash: "hash-\(id)",
        fileMTime: created,
        indexedAt: created
    )
}

private func photoAsset(id: String, modified: Date, width: Int) -> Asset {
    Asset(
        id: id,
        sourceID: Source.photosLibraryID,
        filePath: nil,
        photosLocalIdentifier: String(id.dropFirst("photos:".count)),
        mediaKind: .photo,
        createdAt: modified,
        modifiedAt: modified,
        pixelWidth: width,
        pixelHeight: width,
        fileSize: nil,
        duration: nil,
        latitude: 1,
        longitude: 2,
        contentHash: nil,
        fileMTime: modified
    )
}
