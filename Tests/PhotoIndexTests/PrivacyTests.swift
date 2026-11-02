import XCTest
@testable import PhotoIndex

final class HiddenAlbumTests: XCTestCase {
    func testHiddenItemsLeaveTheLibraryAndStayInTheHiddenAlbum() throws {
        let database = try IndexDatabase.inMemory()
        try database.save(source: Source(id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk", bookmarkData: nil, enabled: true, lastScanAt: nil))
        var secret = sample(id: "secret", source: "desk", kind: .photo, created: date(2024, 6, 2), path: "/desk/secret-lighthouse.jpg")
        secret.latitude = 41.15
        secret.longitude = -8.61
        secret.placeName = "Porto"
        try database.applyChanges(inserted: [
            sample(id: "public", source: "desk", kind: .photo, created: date(2024, 6, 3), path: "/desk/public.jpg"),
            secret
        ], updated: [], deletedIDs: [])

        try database.setHidden(true, assetIDs: ["secret"])

        let visible = try database.fetchAssets(matching: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertEqual(visible.map(\.id), ["public"])
        let hidden = try database.fetchAssets(matching: LibraryQuery(sourceIDs: ["desk"], visibility: .hidden))
        XCTAssertEqual(hidden.map(\.id), ["secret"])
        XCTAssertTrue(try XCTUnwrap(database.asset(id: "secret")).isHidden)

        let counts = try database.libraryCounts(enabledSourceIDs: ["desk"])
        XCTAssertEqual(counts.enabledTotal, 1)
        XCTAssertEqual(counts.bySource["desk"], 1)
        XCTAssertEqual(counts.hiddenCount, 1)
        XCTAssertEqual(counts.byMediaKind[.photo], 1)

        let found = try database.searchLibrary(plan: SearchPlan.parse("lighthouse"), scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertTrue(found.isEmpty)
        let inAlbum = try database.searchLibrary(
            plan: SearchPlan.parse("lighthouse"),
            scope: LibraryQuery(sourceIDs: ["desk"], visibility: .hidden)
        )
        XCTAssertEqual(inAlbum.map(\.asset.id), ["secret"])

        let points = try database.geoPoints(sourceIDs: ["desk"])
        XCTAssertEqual(points.map(\.id), [])
        let memories = try database.memoryAssets(sourceIDs: ["desk"])
        XCTAssertEqual(memories.map(\.id), ["public"])

        var rescanned = secret
        rescanned.pixelWidth = 80
        rescanned.isHidden = false
        try database.applyChanges(inserted: [], updated: [rescanned], deletedIDs: [])
        let kept = try XCTUnwrap(database.asset(id: "secret"))
        XCTAssertTrue(kept.isHidden)
        XCTAssertEqual(kept.pixelWidth, 80)
    }

    func testHiddenLockFollowsInactivityAndTimeoutButNotThePasswordPrompt() {
        let unlocked = date(2024, 6, 2)
        XCTAssertFalse(HiddenLock.shouldLock(inactive: false, authenticating: false, lastActivity: unlocked, now: unlocked.addingTimeInterval(59)))
        XCTAssertTrue(HiddenLock.shouldLock(inactive: false, authenticating: false, lastActivity: unlocked, now: unlocked.addingTimeInterval(60)))
        XCTAssertTrue(HiddenLock.shouldLock(inactive: true, authenticating: false, lastActivity: unlocked, now: unlocked))
        XCTAssertFalse(HiddenLock.shouldLock(inactive: true, authenticating: true, lastActivity: unlocked, now: unlocked.addingTimeInterval(120)))
    }
}

final class DeviceImportTests: XCTestCase {
    func testMonthFoldersDedupeAndNeverDelete() {
        let calendar = utcCalendar()
        let june = date(2024, 6, 15)
        let july = date(2024, 7, 2)
        let first = DeviceFile(name: "IMG_0001.JPG", byteSize: 100, createdAt: june)
        let again = DeviceFile(name: "DCIM/IMG_0001.JPG", byteSize: 100, createdAt: june)
        let different = DeviceFile(name: "IMG_0001.JPG", byteSize: 250, createdAt: june)
        let nextMonth = DeviceFile(name: "IMG_0002.JPG", byteSize: 80, createdAt: july)
        let undated = DeviceFile(name: "clip.mov", byteSize: 40, createdAt: nil)

        XCTAssertEqual(DeviceImportPlan.monthDirectory(createdAt: june, calendar: calendar), "2024/06")
        XCTAssertEqual(DeviceImportPlan.monthDirectory(createdAt: nil, calendar: calendar), "undated")
        XCTAssertEqual(first.signature, again.signature)

        let planned = DeviceImportPlan.plan(
            files: [first, again, different, nextMonth, undated],
            existingSizes: ["2024/07/IMG_0002.JPG": 80],
            importedSignatures: [],
            calendar: calendar
        )
        XCTAssertEqual(planned.map(\.relativePath), [
            "2024/06/IMG_0001.JPG",
            "2024/06/IMG_0001.JPG",
            "2024/06/IMG_0001 2.JPG",
            "2024/07/IMG_0002.JPG",
            "undated/clip.mov"
        ])
        XCTAssertEqual(planned.map(\.skip), [false, true, false, true, false])

        let known = DeviceImportPlan.plan(
            files: [first],
            existingSizes: [:],
            importedSignatures: [first.signature],
            calendar: calendar
        )
        XCTAssertTrue(known[0].skip)

        let request = DeviceImportPlan.downloadRequest(rootPath: "/Imports", relativePath: "2024/06/IMG_0001.JPG")
        XCTAssertEqual(request.directoryPath, "/Imports/2024/06")
        XCTAssertEqual(request.fileName, "IMG_0001.JPG")
        XCTAssertFalse(request.overwrite)
        XCTAssertFalse(request.deleteAfterDownload)
        XCTAssertFalse(request.includeSidecars)
    }

    func testExistingSizesUseMonthRelativePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let month = root.appendingPathComponent("2024/06", isDirectory: true)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: month.appendingPathComponent("a.jpg"))
        let sizes = DeviceImportPlan.existingSizes(in: root)
        XCTAssertEqual(sizes["2024/06/a.jpg"], 3)
        try? FileManager.default.removeItem(at: root)
    }
}

final class PauseAndCaptureToolTests: XCTestCase {
    func testPauseOnLowPowerLowBatteryAndHeat() {
        XCTAssertEqual(
            BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: false, onBattery: true, batteryPercent: 19, thermalSeriousOrCritical: false)),
            .lowBattery
        )
        XCTAssertEqual(
            BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: false, onBattery: true, batteryPercent: 20, thermalSeriousOrCritical: false)),
            .lowBattery
        )
        XCTAssertNil(BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: false, onBattery: true, batteryPercent: 21, thermalSeriousOrCritical: false)))
        XCTAssertNil(BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: false, onBattery: false, batteryPercent: 5, thermalSeriousOrCritical: false)))
        XCTAssertNil(BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: false, onBattery: true, batteryPercent: nil, thermalSeriousOrCritical: false)))
        XCTAssertEqual(
            BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: true, onBattery: false, batteryPercent: 90, thermalSeriousOrCritical: false)),
            .lowPower
        )
        XCTAssertEqual(
            BackgroundPause.reason(for: PowerSnapshot(lowPowerMode: true, onBattery: true, batteryPercent: 10, thermalSeriousOrCritical: true)),
            .thermal
        )
        XCTAssertTrue(BackgroundPause.message(.lowPower).contains("Low Power Mode"))
        XCTAssertTrue(BackgroundPause.message(.thermal).contains("warm"))
    }

    func testCaptureToolFoldersFromPreferences() throws {
        let home = URL(fileURLWithPath: "/Users/ada", isDirectory: true)
        let cleanShot = CaptureToolPreferences.directory(
            in: ["exportPath": "~/Pictures/CleanShot", "typeface": "Nope"],
            keys: CaptureToolPreferences.cleanShotKeys,
            home: home
        )
        XCTAssertEqual(cleanShot, "/Users/ada/Pictures/CleanShot")

        let shottr = CaptureToolPreferences.directory(
            in: ["typeface": "Fira", "defaultFolder": "file:///Users/ada/Shots"],
            keys: CaptureToolPreferences.shottrKeys,
            home: home
        )
        XCTAssertEqual(shottr, "/Users/ada/Shots")
        XCTAssertNil(CaptureToolPreferences.directory(in: ["typeface": "Fira"], keys: CaptureToolPreferences.shottrKeys, home: home))

        let matches = [
            CaptureToolMatch(id: CaptureToolPreferences.cleanShotID, displayName: "CleanShot X", path: "/Users/ada/Desktop"),
            CaptureToolMatch(id: CaptureToolPreferences.shottrID, displayName: "Shottr", path: "/Users/ada/Shots/")
        ]
        let offered = CaptureToolPreferences.offering(matches, existingRoots: ["/Users/ada/Desktop"])
        XCTAssertEqual(offered.map(\.id), [CaptureToolPreferences.shottrID])
        XCTAssertEqual(offered.first?.path, "/Users/ada/Shots")

        let database = try IndexDatabase.inMemory()
        try database.synchronizeCaptureTools(offered.map(CaptureToolPreferences.source(for:)))
        var stored = try XCTUnwrap(database.source(id: CaptureToolPreferences.shottrID))
        stored.enabled = false
        try database.save(source: stored)
        let moved = CaptureToolMatch(id: CaptureToolPreferences.shottrID, displayName: "Shottr", path: "/Users/ada/Pictures/Shottr")
        try database.synchronizeCaptureTools([CaptureToolPreferences.source(for: moved)])
        let updated = try XCTUnwrap(database.source(id: CaptureToolPreferences.shottrID))
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.rootPath, "/Users/ada/Pictures/Shottr")
        XCTAssertEqual(updated.kind, .captureTool)
        XCTAssertEqual(MediaClassifier.kind(relativePath: "CleanShot 2024.png", sourceKind: .captureTool), .screenshot)
        XCTAssertEqual(MediaClassifier.kind(relativePath: "recording.mov", sourceKind: .captureTool), .screenRecording)
    }
}

final class WebPCodecTests: XCTestCase {
    func testWebPRoundTripOfASolidImage() throws {
        let width = 4
        let height = 4
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba[index] = 220
            rgba[index + 1] = 30
            rgba[index + 2] = 40
            rgba[index + 3] = 255
        }
        let data = try WebPCodec.encodeRGBA(width: width, height: height, rgba: rgba, quality: 100)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x52, 0x49, 0x46, 0x46])
        let decoded = try WebPCodec.decodeRGBA(data)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.rgba.count, rgba.count)
        var worst = 0
        for index in stride(from: 0, to: rgba.count, by: 4) {
            for channel in 0..<3 {
                worst = max(worst, abs(Int(rgba[index + channel]) - Int(decoded.rgba[index + channel])))
            }
            XCTAssertEqual(decoded.rgba[index + 3], 255)
        }
        XCTAssertLessThan(worst, 12)

        let rows = WebPCodec.applyingEncoder([
            EncodeAvailability(format: .webp, available: false, unavailableReason: "ImageIO cannot write WebP.")
        ])
        XCTAssertTrue(rows[0].available)
        XCTAssertNil(rows[0].unavailableReason)
    }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
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
        duration: nil,
        latitude: nil,
        longitude: nil,
        contentHash: "hash-\(id)",
        fileMTime: created,
        indexedAt: created
    )
}
