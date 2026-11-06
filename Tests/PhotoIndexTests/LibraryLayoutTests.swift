import XCTest
@testable import PhotoIndex

final class LibraryLayoutTests: XCTestCase {
    func testFavoritesStickAcrossRescanAndFilterTheLibrary() throws {
        let database = try IndexDatabase.inMemory()
        try database.save(source: Source(
            id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk",
            bookmarkData: nil, enabled: true, lastScanAt: nil
        ))
        let kept = photo(id: "kept", created: date(2026, 10, 28))
        var loved = photo(id: "loved", created: date(2026, 10, 27))
        loved.placeName = "Kushavati, Goa"
        try database.applyChanges(inserted: [kept, loved], updated: [], deletedIDs: [])
        try database.setFavorite(true, assetIDs: ["loved"])

        let favorites = try database.fetchAssets(matching: LibraryQuery(sourceIDs: ["desk"], favoritesOnly: true))
        XCTAssertEqual(favorites.map(\.id), ["loved"])
        XCTAssertTrue(try XCTUnwrap(database.asset(id: "loved")).isFavorite)
        XCTAssertFalse(try XCTUnwrap(database.asset(id: "kept")).isFavorite)

        let counts = try database.libraryCounts(enabledSourceIDs: ["desk"])
        XCTAssertEqual(counts.favoriteCount, 1)
        XCTAssertEqual(counts.enabledTotal, 2)

        var rescanned = loved
        rescanned.pixelWidth = 80
        rescanned.isFavorite = false
        try database.applyChanges(inserted: [], updated: [rescanned], deletedIDs: [])
        let roundTrip = try XCTUnwrap(database.asset(id: "loved"))
        XCTAssertTrue(roundTrip.isFavorite)
        XCTAssertEqual(roundTrip.pixelWidth, 80)

        try database.setFavorite(false, assetIDs: ["loved"])
        XCTAssertFalse(try XCTUnwrap(database.asset(id: "loved")).isFavorite)
        XCTAssertEqual(try database.libraryCounts(enabledSourceIDs: ["desk"]).favoriteCount, 0)
    }

    func testRecentsUseAThirtyDayWindow() throws {
        let database = try IndexDatabase.inMemory()
        try database.save(source: Source(
            id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk",
            bookmarkData: nil, enabled: true, lastScanAt: nil
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(2026, 11, 2, hour: 12)
        let recent = photo(id: "recent", created: calendar.date(byAdding: .day, value: -10, to: now)!)
        let edge = photo(id: "edge", created: calendar.date(byAdding: .day, value: -30, to: now)!)
        let old = photo(id: "old", created: calendar.date(byAdding: .day, value: -31, to: now)!)
        let undated = photo(id: "none", created: nil)
        try database.applyChanges(inserted: [recent, edge, old, undated], updated: [], deletedIDs: [])

        XCTAssertTrue(RecentsWindow.contains(recent.createdAt, now: now, calendar: calendar))
        XCTAssertTrue(RecentsWindow.contains(edge.createdAt, now: now, calendar: calendar))
        XCTAssertFalse(RecentsWindow.contains(old.createdAt, now: now, calendar: calendar))
        XCTAssertFalse(RecentsWindow.contains(nil, now: now, calendar: calendar))

        let since = RecentsWindow.start(now: now, calendar: calendar)
        let found = try database.fetchAssets(matching: LibraryQuery(sourceIDs: ["desk"], createdAfter: since))
        XCTAssertEqual(found.map(\.id), ["recent", "edge"])
        XCTAssertEqual(try database.countAssets(matching: LibraryQuery(sourceIDs: ["desk"], createdAfter: since)), 2)
    }

    func testTimelineGroupsByYearMonthAndDayAndKeepsTheDominantPlace() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = date(2026, 11, 2, hour: 15)
        let todayEarly = photo(id: "today-early", created: date(2026, 11, 2, hour: 8), place: "Home")
        let todayLate = photo(id: "today-late", created: date(2026, 11, 2, hour: 18), place: "Home")
        let yesterday = photo(id: "yesterday", created: date(2026, 11, 1, hour: 9), place: "Panaji")
        let goaMorning = photo(id: "goa-am", created: date(2026, 10, 28, hour: 9), place: "Kushavati, Goa")
        let goaEvening = photo(id: "goa-pm", created: date(2026, 10, 28, hour: 19), place: "Kushavati, Goa")
        let goaOther = photo(id: "goa-other", created: date(2026, 10, 28, hour: 12), place: "Panaji")
        let october = photo(id: "oct-11", created: date(2026, 10, 11, hour: 12), place: "Kushavati, Goa")
        let older = photo(id: "older", created: date(2024, 1, 2, hour: 12))
        let undated = photo(id: "undated", created: nil)
        let assets = [older, goaMorning, todayEarly, undated, goaOther, october, yesterday, goaEvening, todayLate]

        let days = TimelineGrouping.sections(assets: assets, scale: .days, sort: .newest, calendar: calendar, now: now)
        XCTAssertEqual(days.map(\.title), ["Today", "Yesterday", "28 Oct 2026", "11 Oct 2026", "2 Jan 2024", "No Date"])
        XCTAssertEqual(days.map(\.place), ["Home", "Panaji", "Kushavati, Goa", "Kushavati, Goa", nil, nil])
        XCTAssertEqual(days[0].assets.map(\.id), ["today-late", "today-early"])
        XCTAssertEqual(days[2].assets.map(\.id), ["goa-pm", "goa-other", "goa-am"])

        let oldestDays = TimelineGrouping.sections(assets: assets, scale: .days, sort: .oldest, calendar: calendar, now: now)
        XCTAssertEqual(oldestDays.map(\.title), ["2 Jan 2024", "11 Oct 2026", "28 Oct 2026", "Yesterday", "Today", "No Date"])
        XCTAssertEqual(oldestDays[2].assets.map(\.id), ["goa-am", "goa-other", "goa-pm"])

        let months = TimelineGrouping.sections(assets: assets, scale: .months, sort: .newest, calendar: calendar, now: now)
        XCTAssertEqual(months.map(\.title), ["November 2026", "October 2026", "January 2024", "No Date"])
        XCTAssertEqual(months[1].place, "Kushavati, Goa")

        let years = TimelineGrouping.sections(assets: assets, scale: .years, sort: .newest, calendar: calendar, now: now)
        XCTAssertEqual(years.map(\.title), ["2026", "2024", "No Date"])
        XCTAssertEqual(years[0].assets.count, 7)

        let all = TimelineGrouping.sections(assets: assets, scale: .all, sort: .newest, calendar: calendar, now: now)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "")
        XCTAssertNil(all[0].place)
        XCTAssertEqual(all[0].assets.first?.id, "today-late")
        XCTAssertEqual(all[0].assets.last?.id, "undated")
    }
}

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func photo(id: String, created: Date?, place: String? = nil) -> Asset {
    Asset(
        id: id,
        sourceID: "desk",
        filePath: "/desk/\(id).jpg",
        photosLocalIdentifier: nil,
        mediaKind: .photo,
        createdAt: created,
        modifiedAt: created,
        pixelWidth: 100,
        pixelHeight: 80,
        fileSize: 1000,
        duration: nil,
        latitude: place == nil ? nil : 15.3,
        longitude: place == nil ? nil : 73.9,
        placeName: place,
        contentHash: "hash-\(id)",
        fileMTime: created,
        indexedAt: created
    )
}
