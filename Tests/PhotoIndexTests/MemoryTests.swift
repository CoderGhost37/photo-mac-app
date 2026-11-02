import XCTest
@testable import PhotoIndex

final class MemoryTests: XCTestCase {
    func testMapClustersSplitAsTheCellShrinks() {
        let points = [
            GeoPoint(id: "a", latitude: 10, longitude: 10),
            GeoPoint(id: "b", latitude: 10.2, longitude: 10.2),
            GeoPoint(id: "bad", latitude: 120, longitude: 0)
        ]
        let wide = MapGrid.cluster(points, latitudeCell: 1, longitudeCell: 1)
        XCTAssertEqual(wide.count, 1)
        XCTAssertEqual(wide[0].count, 2)
        XCTAssertEqual(wide[0].memberIDs, ["a", "b"])

        let tight = MapGrid.cluster(points, latitudeCell: 0.1, longitudeCell: 0.1)
        XCTAssertEqual(tight.count, 2)
        XCTAssertTrue(tight.allSatisfy { $0.count == 1 })

        let span = MapGrid.cellSize(latitudeSpan: 80, longitudeSpan: 60, divisions: 8)
        XCTAssertEqual(span.latitude, 10, accuracy: 0.0001)
        XCTAssertEqual(span.longitude, 7.5, accuracy: 0.0001)
        XCTAssertEqual(MapGrid.cluster([], latitudeCell: 1, longitudeCell: 1).count, 0)
        XCTAssertEqual(MapGrid.cluster(points, latitudeCell: 0, longitudeCell: 1).count, 2)

        let fitted = MapGrid.fittingSpan(for: [
            GeoPoint(id: "a", latitude: 0, longitude: 0),
            GeoPoint(id: "b", latitude: 0, longitude: 2)
        ])
        XCTAssertEqual(fitted?.centerLongitude ?? 0, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(fitted?.longitudeDelta ?? 0, 2)
    }

    func testPlaceKeysPaceAndSearchableNames() {
        XCTAssertEqual(PlaceName.cacheKey(latitude: 38.722, longitude: -9.139), "38.72,-9.14")
        XCTAssertEqual(PlaceName.cacheKey(latitude: 38.722, longitude: -9.141), PlaceName.cacheKey(latitude: 38.718, longitude: -9.139))
        XCTAssertNil(PlaceName.cacheKey(latitude: 91, longitude: 0))
        XCTAssertEqual(PlaceName.join(locality: "Lisbon", region: "Lisbon", country: "Portugal"), "Lisbon, Portugal")
        XCTAssertEqual(PlaceName.join(locality: "  ", region: nil, country: "Portugal"), "Portugal")
        XCTAssertEqual(PlaceName.searchable(stored: "Lisbon", geocoded: "Lisbon, Portugal"), "Lisbon Lisbon, Portugal")

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(GeocodePace.delay(since: nil, now: now), 0)
        XCTAssertEqual(GeocodePace.delay(since: now.addingTimeInterval(-0.1), now: now), 1.0, accuracy: 0.0001)
        XCTAssertEqual(GeocodePace.delay(since: now.addingTimeInterval(-5), now: now), 0)
        XCTAssertEqual(GeocodePace.maximumPerPass, 30)
        XCTAssertFalse(GeocodePace.shouldRetryFailure(lookedUpAt: now, now: now.addingTimeInterval(10)))
        XCTAssertTrue(GeocodePace.shouldRetryFailure(lookedUpAt: now, now: now.addingTimeInterval(GeocodePace.failureRetry)))
        let km = GeoDistance.kilometers(latitude: 0, longitude: 0, otherLatitude: 1, otherLongitude: 0)
        XCTAssertEqual(km, 111.19, accuracy: 0.2)
    }

    func testGeocodedPlaceIsCachedAndSearchableWithoutLosingItOnRescan() throws {
        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        let first = located(id: "near", latitude: 41.15, longitude: -8.61)
        let second = located(id: "also", latitude: 41.151, longitude: -8.612)
        let other = located(id: "far", latitude: 48.85, longitude: 2.35)
        try database.applyChanges(inserted: [first, second, other], updated: [], deletedIDs: [])

        let lookups = try database.placeLookups(sourceIDs: ["desk"], limit: 10)
        XCTAssertEqual(lookups.count, 2)
        let porto = try XCTUnwrap(lookups.first { $0.assetIDs.contains("near") })
        XCTAssertEqual(Set(porto.assetIDs), ["also", "near"])
        XCTAssertEqual(porto.cacheKey, PlaceName.cacheKey(latitude: 41.15, longitude: -8.61))

        let lookedUp = Date(timeIntervalSince1970: 50)
        try database.savePlaceCache(key: porto.cacheKey, latitude: porto.latitude, longitude: porto.longitude, placeName: "Porto, Portugal", lookedUpAt: lookedUp)
        let cached = try XCTUnwrap(try database.cachedPlace(key: porto.cacheKey))
        XCTAssertEqual(cached.placeName, "Porto, Portugal")
        try database.setGeocodedPlace(assetIDs: porto.assetIDs, placeName: "Porto, Portugal")
        let found = try database.searchLibrary(plan: SearchPlan.parse("porto"), scope: LibraryQuery(sourceIDs: ["desk"]))
        XCTAssertEqual(Set(found.map(\.asset.id)), ["also", "near"])

        var rescanned = first
        rescanned.geocodedPlace = nil
        rescanned.fileSize = 180
        try database.applyChanges(inserted: [], updated: [rescanned], deletedIDs: [])
        XCTAssertEqual(try database.asset(id: "near")?.geocodedPlace, "Porto, Portugal")

        var moved = first
        moved.latitude = 10
        moved.geocodedPlace = nil
        try database.applyChanges(inserted: [], updated: [moved], deletedIDs: [])
        XCTAssertNil(try database.asset(id: "near")?.geocodedPlace)

        try database.savePlaceCache(key: "0.00,0.00", latitude: 0, longitude: 0, placeName: nil, lookedUpAt: lookedUp)
        XCTAssertNil(try database.cachedPlace(key: "0.00,0.00")?.placeName)
    }

    func testSubjectClusteringKeepsNamesMergesAndRejections() throws {
        let mina = SubjectSample(id: "a", assetID: "one", kind: .person, vector: [1, 0])
        let close = SubjectSample(id: "b", assetID: "two", kind: .person, vector: [1, 0])
        let other = SubjectSample(id: "c", assetID: "three", kind: .person, vector: [0, 1])
        let cat = SubjectSample(id: "d", assetID: "four", kind: .cat, vector: [1, 0])
        var counter = 0
        let samples = [other, close, mina, cat]
        let grouped = SubjectGrouping.assign(samples: samples, clusters: [], threshold: 0.2) { _ in
            counter += 1
            return "c\(counter)"
        }
        let people = grouped.filter { $0.kind == .person }
        XCTAssertEqual(people.count, 2)
        let pair = try XCTUnwrap(people.first { Set($0.memberIDs) == ["a", "b"] })
        XCTAssertEqual(grouped.filter { $0.kind == .cat }.count, 1)

        let named = SubjectGrouping.rename(grouped, id: pair.id, name: "  Mina  ")
        XCTAssertEqual(named.first { $0.id == pair.id }?.name, "Mina")

        let rejected = SubjectCluster(id: "keep", kind: .person, name: "Mina", memberIDs: ["a"], rejectedAssetIDs: ["two"])
        let held = SubjectGrouping.assign(samples: [mina, close], clusters: [rejected], threshold: 0.2) { _ in "new" }
        XCTAssertEqual(held.first { $0.id == "keep" }?.memberIDs, ["a"])
        XCTAssertEqual(Set(held.first { $0.memberIDs == ["b"] }?.rejectedAssetIDs ?? []), [])
        XCTAssertFalse(held.contains { $0.id == "keep" && $0.memberIDs.contains("b") })

        let absorbed = SubjectCluster(id: "other", kind: .person, name: "M.", memberIDs: ["c"], rejectedAssetIDs: [])
        let merged = SubjectGrouping.merge(
            clusters: [rejected, absorbed],
            samples: [mina, other],
            keeping: "keep",
            absorbing: "other"
        )
        XCTAssertEqual(merged.map(\.id), ["keep"])
        XCTAssertEqual(Set(merged[0].memberIDs), ["a", "c"])
        XCTAssertEqual(merged[0].name, "Mina")

        let removed = SubjectGrouping.remove(assetID: "three", from: "keep", clusters: merged, samples: [mina, other])
        XCTAssertEqual(removed[0].memberIDs, ["a"])
        XCTAssertTrue(removed[0].rejectedAssetIDs.contains("three"))
        let again = SubjectGrouping.assign(samples: [mina, other], clusters: removed, threshold: 0.2) { _ in "solo" }
        XCTAssertFalse(again.first { $0.id == "keep" }?.memberIDs.contains("c") ?? true)
        XCTAssertEqual(SubjectGrouping.personDistance, 0.35, accuracy: 0.0001)
        XCTAssertEqual(SubjectGrouping.petDistance, 0.40, accuracy: 0.0001)

        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        try database.applyChanges(inserted: [
            located(id: "one", latitude: 1, longitude: 1),
            located(id: "two", latitude: 1, longitude: 1),
            located(id: "three", latitude: 1, longitude: 1)
        ], updated: [], deletedIDs: [])
        try database.replaceSubjects(assetID: "one", contentToken: token("one"), subjects: [stored(mina)], labels: [], imageVector: [1, 0])
        try database.replaceSubjects(assetID: "two", contentToken: token("two"), subjects: [stored(close)], labels: [], imageVector: [1, 0])
        try database.replaceSubjects(assetID: "three", contentToken: token("three"), subjects: [stored(other)], labels: [SceneLabel(label: "pizza", confidence: 0.8)], imageVector: [0, 1])
        var issued = 0
        try database.assignNewSubjects {
            issued += 1
            return "id\(issued)"
        }
        let records = try database.subjectClusters()
        let together = try XCTUnwrap(records.first { Set($0.assetIDs) == ["one", "two"] })
        try database.renameSubject(clusterID: together.id, name: "Mina")
        XCTAssertEqual(try database.subjectClusters().first { $0.id == together.id }?.name, "Mina")
        let solo = try XCTUnwrap(try database.subjectClusters().first { $0.assetIDs == ["three"] })
        try database.mergeSubjects(keeping: together.id, absorbing: solo.id)
        let afterMerge = try XCTUnwrap(try database.subjectClusters().first { $0.id == together.id })
        XCTAssertEqual(Set(afterMerge.assetIDs), ["one", "three", "two"])
        try database.removeSubject(assetID: "three", from: together.id)
        let afterRemove = try XCTUnwrap(try database.subjectClusters().first { $0.id == together.id })
        XCTAssertFalse(afterRemove.assetIDs.contains("three"))
        try database.assignNewSubjects { "again" }
        let rejoined = try XCTUnwrap(try database.subjectClusters().first { $0.id == together.id })
        XCTAssertFalse(rejoined.assetIDs.contains("three"))
        XCTAssertEqual(UnderstandingPlan.needsScan(try database.understandingStamps()), [])
    }

    func testDuplicateGroupsSeparateExactHashesFromSimilarPrints() {
        let same = DuplicateCandidate(id: "a", contentHash: "hash", vector: [1, 0])
        let copy = DuplicateCandidate(id: "b", contentHash: "hash", vector: [1, 0])
        let similar = DuplicateCandidate(id: "c", contentHash: "other", vector: [0.98, 0.2])
        let far = DuplicateCandidate(id: "d", contentHash: "far", vector: [0, 1])
        let blank = DuplicateCandidate(id: "e", contentHash: "  ", vector: nil)
        let groups = DuplicateGrouping.groups([far, copy, blank, same, similar], nearThreshold: 0.45)
        let exact = groups.filter { $0.kind == .exact }
        XCTAssertEqual(exact.map(\.assetIDs), [["a", "b"]])
        let near = groups.filter { $0.kind == .near }
        XCTAssertEqual(near.count, 1)
        XCTAssertTrue(near[0].assetIDs.contains("c"))
        XCTAssertTrue(near[0].assetIDs.contains("a") || near[0].assetIDs.contains("b"))
        XCTAssertFalse(near[0].assetIDs.contains("d"))
        XCTAssertFalse(groups.contains { $0.kind == .near && Set($0.assetIDs) == ["a", "b"] })
        XCTAssertTrue(DuplicateGrouping.groups([same, copy]).filter { $0.kind == .near }.isEmpty)
        XCTAssertNil(FeatureDistance.unitEuclidean([0, 0], [0, 0]))
        XCTAssertEqual(FeatureDistance.unitEuclidean([3, 0], [6, 0]) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(DuplicateGrouping.nearDuplicateDistance, 0.45, accuracy: 0.0001)
    }

    func testHighlightRulesForAnniversariesTripsAndFood() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15)))
        func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        var assets: [MemoryAsset] = []
        for index in 0..<5 {
            assets.append(MemoryAsset(id: "home-\(index)", createdAt: day(2026, 11, 2, hour: index), latitude: 0, longitude: 0, placeName: "Home"))
        }
        assets.append(MemoryAsset(id: "year", createdAt: day(2025, 11, 2), latitude: 0, longitude: 0, placeName: "Home", labels: ["pizza"]))
        assets.append(MemoryAsset(id: "two-years", createdAt: day(2024, 11, 2), latitude: 0, longitude: 0))
        assets.append(MemoryAsset(id: "other-day", createdAt: day(2025, 11, 3), latitude: 0, longitude: 0))
        assets.append(MemoryAsset(id: "recent-old", createdAt: day(2026, 10, 18), latitude: 0, longitude: 0))
        assets.append(MemoryAsset(id: "yesterday", createdAt: day(2026, 11, 1), latitude: 0, longitude: 0))
        for (index, hour) in [10, 12, 30].enumerated() {
            assets.append(MemoryAsset(
                id: "trip-\(index)",
                createdAt: day(2026, 8, 1, hour: hour > 23 ? 12 : hour).addingTimeInterval(hour > 23 ? 20 * 3600 : 0),
                latitude: 10,
                longitude: 10,
                placeName: "Lisbon"
            ))
        }
        assets.append(MemoryAsset(id: "trip-far", createdAt: day(2026, 8, 4), latitude: 11, longitude: 10, placeName: "Lisbon"))
        assets.append(MemoryAsset(id: "gap-1", createdAt: day(2026, 1, 1), latitude: -20, longitude: 40))
        assets.append(MemoryAsset(id: "gap-2", createdAt: day(2026, 1, 4), latitude: -20, longitude: 40))
        assets.append(MemoryAsset(id: "gap-3", createdAt: day(2026, 1, 7), latitude: -20, longitude: 40))
        assets.append(MemoryAsset(id: "food-1", createdAt: day(2026, 5, 1), labels: ["slice of pizza"]))
        assets.append(MemoryAsset(id: "food-2", createdAt: day(2026, 5, 2), foodScore: 0.91))
        assets.append(MemoryAsset(id: "dog", createdAt: day(2026, 5, 3), labels: ["dog"], foodScore: 0.1))
        for index in 0..<3 {
            assets.append(MemoryAsset(id: "mina-\(index)", createdAt: day(2026, 4, index + 1), personIDs: ["mina"]))
        }
        assets.append(MemoryAsset(id: "biscuit", createdAt: day(2026, 4, 8), petIDs: ["biscuit"]))

        let stories = HighlightRules.stories(assets: assets, names: ["mina": "Mina"], now: now, calendar: calendar)
        let onThisDay = try XCTUnwrap(stories.first { $0.kind == .onThisDay })
        XCTAssertEqual(onThisDay.assetIDs, ["year", "two-years"])
        XCTAssertFalse(onThisDay.assetIDs.contains("home-0"))
        XCTAssertEqual(stories.first { $0.id == "years-2025" }?.title, "1 year ago")
        XCTAssertEqual(stories.first { $0.id == "years-2024" }?.title, "2 years ago")
        XCTAssertEqual(stories.first { $0.kind == .recentDay && $0.title == "Today" }?.assetIDs.count, 5)
        XCTAssertEqual(stories.first { $0.title == "Yesterday" }?.assetIDs, ["yesterday"])
        XCTAssertFalse(stories.contains { $0.assetIDs == ["recent-old"] })

        let trip = try XCTUnwrap(stories.first { $0.kind == .trip })
        XCTAssertEqual(trip.title, "Lisbon")
        XCTAssertEqual(Set(trip.assetIDs), ["trip-0", "trip-1", "trip-2"])
        XCTAssertFalse(trip.assetIDs.contains("home-0"))
        XCTAssertFalse(trip.assetIDs.contains("trip-far"))
        XCTAssertFalse(stories.contains { $0.assetIDs.contains("gap-1") && $0.kind == .trip })

        XCTAssertEqual(stories.first { $0.kind == .person }?.title, "Mina")
        XCTAssertEqual(stories.first { $0.kind == .person }?.count, 3)
        XCTAssertNil(stories.first { $0.kind == .pet })
        let food = try XCTUnwrap(stories.first { $0.kind == .food })
        XCTAssertEqual(Set(food.assetIDs), ["year", "food-1", "food-2"])
        XCTAssertFalse(food.assetIDs.contains("dog"))
        let forYou = try XCTUnwrap(stories.first { $0.kind == .forYou })
        XCTAssertEqual(forYou.assetIDs.count, Set(forYou.assetIDs).count)
        XCTAssertTrue(forYou.assetIDs.contains("year"))
        XCTAssertEqual(stories.map(\.kind).first, .forYou)

        let memory = try XCTUnwrap(HighlightRules.roulette(assets: assets, count: 5, seed: 7, now: now, calendar: calendar))
        let again = HighlightRules.roulette(assets: assets, count: 5, seed: 7, now: now, calendar: calendar)
        XCTAssertEqual(memory.assetIDs, again?.assetIDs)
        XCTAssertEqual(memory.assetIDs.count, 5)
        XCTAssertTrue(memory.assetIDs.allSatisfy { id in
            guard let created = assets.first(where: { $0.id == id })?.createdAt else { return false }
            return now.timeIntervalSince(created) >= HighlightRules.roulettePreferredAge
        })
        XCTAssertNil(HighlightRules.roulette(assets: [], count: 5, seed: 1, now: now))
        XCTAssertTrue(FoodLabels.matches(["Hot dog"]))
        XCTAssertFalse(FoodLabels.matches(["landscape"]))
        XCTAssertFalse(HighlightRules.isFood(MemoryAsset(id: "x", foodScore: 0.1)))
    }

    func testDuplicateCandidatesAndMemoryRowsRoundTrip() throws {
        let database = try IndexDatabase.inMemory()
        try saveDesk(database)
        try database.applyChanges(inserted: [
            located(id: "a", latitude: 0, longitude: 0, hash: "same"),
            located(id: "b", latitude: 0.1, longitude: 0.1, hash: "same"),
            located(id: "c", latitude: nil, longitude: nil, hash: "solo")
        ], updated: [], deletedIDs: [])
        let shared = ContentToken.make(contentHash: "same", fileSize: 100, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try database.replaceSubjects(
            assetID: "a",
            contentToken: shared,
            subjects: [],
            labels: [SceneLabel(label: "bread", confidence: 0.5)],
            imageVector: [1, 0]
        )
        try database.replaceSubjects(
            assetID: "b",
            contentToken: shared,
            subjects: [],
            labels: [],
            imageVector: [0, 1]
        )
        let candidates = try database.duplicateCandidates(sourceIDs: ["desk"])
        let groups = DuplicateGrouping.groups(candidates, nearThreshold: 0.1)
        XCTAssertEqual(groups.map(\.kind), [.exact])
        XCTAssertEqual(Set(groups[0].assetIDs), ["a", "b"])
        let points = try database.geoPoints(sourceIDs: ["desk"])
        XCTAssertEqual(Set(points.map(\.id)), ["a", "b"])
        let memories = try database.memoryAssets(sourceIDs: ["desk"])
        XCTAssertEqual(memories.first { $0.id == "a" }?.labels, ["bread"])
        let stamps = try database.understandingStamps()
        XCTAssertEqual(UnderstandingPlan.needsScan(stamps), ["c"])
        let photo = UnderstandingStamp(assetID: "p", mediaKind: .photo, contentToken: "h:1")
        let done = UnderstandingStamp(assetID: "d", mediaKind: .screenshot, contentToken: "h:1", scannedToken: "h:1")
        let video = UnderstandingStamp(assetID: "v", mediaKind: .video, contentToken: "h:1")
        let stale = UnderstandingStamp(assetID: "s", mediaKind: .photo, contentToken: "h:2", scannedToken: "h:1")
        XCTAssertEqual(UnderstandingPlan.needsScan([video, done, stale, photo]), ["p", "s"])
    }
}

private func saveDesk(_ database: IndexDatabase) throws {
    let source = Source(id: "desk", kind: .folder, displayName: "Desk", rootPath: "/desk", bookmarkData: nil, enabled: true, lastScanAt: nil)
    try database.save(source: source)
}

private func located(id: String, latitude: Double?, longitude: Double?, hash: String? = nil) -> Asset {
    Asset(
        id: id,
        sourceID: "desk",
        filePath: "/desk/\(id).jpg",
        photosLocalIdentifier: nil,
        mediaKind: .photo,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        pixelWidth: 20,
        pixelHeight: 10,
        fileSize: 100,
        duration: nil,
        latitude: latitude,
        longitude: longitude,
        placeName: nil,
        contentHash: hash ?? "hash-\(id)",
        fileMTime: Date(timeIntervalSince1970: 1_700_000_000),
        indexedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func token(_ id: String) -> String {
    ContentToken.make(contentHash: "hash-\(id)", fileSize: 100, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private func stored(_ sample: SubjectSample) -> StoredSubject {
    StoredSubject(
        id: sample.id,
        assetID: sample.assetID,
        kind: sample.kind,
        box: NormalizedBox(x: 0.2, y: 0.3, width: 0.2, height: 0.2),
        confidence: 0.9,
        vector: sample.vector
    )
}
