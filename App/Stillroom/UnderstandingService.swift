import Foundation
import PhotoIndex

/// Reads faces, pets, scene labels, and image prints after a scan, then fills in place names.
/// The photo files are only read. Place names come from Apple's geocoder, one coordinate at a time.
final class UnderstandingService: @unchecked Sendable {
    private let database: IndexDatabase
    private let queue = DispatchQueue(label: "Stillroom.Understanding", qos: .background)
    private var draining = false
    private var again = false
    private let workDirectory: URL
    var onProgress: @Sendable (String?) -> Void = { _ in }
    var onUpdate: @Sendable () -> Void = {}

    init(database: IndexDatabase, home: URL) {
        self.database = database
        self.workDirectory = IndexLocation.workDirectory(home: home)
            .appendingPathComponent("Understanding", isDirectory: true)
    }

    func schedule() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.draining {
                self.again = true
                return
            }
            self.drain()
        }
    }

    private func drain() {
        draining = true
        defer {
            draining = false
            if again {
                again = false
                drain()
            }
        }
        let group = DispatchGroup()
        group.enter()
        Task {
            await self.pass()
            group.leave()
        }
        group.wait()
    }

    private func pass() async {
        guard let stamps = try? database.understandingStamps() else { return }
        let pending = UnderstandingPlan.needsScan(stamps)
        var remaining = pending.count
        if !pending.isEmpty {
            onProgress("Reading faces · \(remaining) left")
        }
        for id in pending {
            if again { break }
            remaining -= 1
            if remaining % 10 == 0 {
                onProgress("Reading faces · \(remaining) left")
            }
            guard let asset = try? database.asset(id: id) else { continue }
            let token = ContentToken.make(contentHash: asset.contentHash, fileSize: asset.fileSize, modifiedAt: asset.fileMTime)
            guard let material = materialize(asset) else { continue }
            defer {
                if material.temporary {
                    try? FileManager.default.removeItem(at: material.url)
                }
            }
            guard let image = RasterImage.cgImage(at: material.url) else { continue }
            guard let read = try? VisionMemory.read(cgImage: image, assetID: asset.id) else { continue }
            try? database.replaceSubjects(
                assetID: asset.id,
                contentToken: token,
                subjects: read.subjects,
                labels: read.labels,
                imageVector: read.imageVector
            )
        }
        if !pending.isEmpty {
            try? database.assignNewSubjects()
            onUpdate()
        }
        let hitCap = await geocode()
        onProgress(nil)
        onUpdate()
        if hitCap {
            again = true
        }
    }

    /// Returns true when this pass stopped because it reached the geocoder cap, so another pass should follow.
    private func geocode() async -> Bool {
        let sourceIDs = (try? database.sources().filter(\.enabled).map(\.id)) ?? []
        guard !sourceIDs.isEmpty else { return false }
        let lookups = (try? database.placeLookups(sourceIDs: sourceIDs, limit: 300)) ?? []
        guard !lookups.isEmpty else { return false }
        onProgress("Finding place names…")
        var lastRequest: Date?
        var requests = 0
        for lookup in lookups {
            if again { return false }
            if let cached = try? database.cachedPlace(key: lookup.cacheKey) {
                if let name = cached.placeName, !name.isEmpty {
                    try? database.setGeocodedPlace(assetIDs: lookup.assetIDs, placeName: name)
                    continue
                }
                if !GeocodePace.shouldRetryFailure(lookedUpAt: cached.lookedUpAt, now: Date()) {
                    continue
                }
            }
            if requests >= GeocodePace.maximumPerPass { return true }
            let wait = GeocodePace.delay(since: lastRequest, now: Date())
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            let name = await ReverseGeocoder.placeName(latitude: lookup.latitude, longitude: lookup.longitude)
            lastRequest = Date()
            requests += 1
            try? database.savePlaceCache(
                key: lookup.cacheKey,
                latitude: lookup.latitude,
                longitude: lookup.longitude,
                placeName: name,
                lookedUpAt: lastRequest ?? Date()
            )
            if let name {
                try? database.setGeocodedPlace(assetIDs: lookup.assetIDs, placeName: name)
            }
        }
        return false
    }

    private func materialize(_ asset: Asset) -> Material? {
        if let path = asset.filePath {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Material(url: URL(fileURLWithPath: path), temporary: false)
        }
        guard let identifier = asset.photosLocalIdentifier else { return nil }
        let directory = workDirectory
        let group = DispatchGroup()
        group.enter()
        var exported: URL?
        Task {
            exported = try? await PhotosLibraryClient.exportOriginal(localIdentifier: identifier, to: directory)
            group.leave()
        }
        group.wait()
        guard let exported else { return nil }
        return Material(url: exported, temporary: true)
    }
}

private struct Material {
    var url: URL
    var temporary: Bool
}
