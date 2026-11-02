import Foundation

public enum PlaceName {
    /// About a kilometer. Photos in the same neighborhood share one lookup.
    public static func cacheKey(latitude: Double, longitude: Double) -> String? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let lat = (latitude * 100).rounded() / 100
        let lon = (longitude * 100).rounded() / 100
        return String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), lat, lon)
    }

    public static func join(locality: String?, region: String?, country: String?) -> String? {
        var parts: [String] = []
        for raw in [locality, region, country] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if parts.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { continue }
            parts.append(trimmed)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    public static func searchable(stored: String?, geocoded: String?) -> String {
        var parts: [String] = []
        for raw in [stored, geocoded] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !parts.contains(trimmed) else { continue }
            parts.append(trimmed)
        }
        return parts.joined(separator: " ")
    }
}

/// CLGeocoder is limited to a slow trickle. The wait is computed here; the app sleeps.
public enum GeocodePace {
    public static let minimumInterval: TimeInterval = 1.1
    public static let maximumPerPass = 30
    public static let failureRetry: TimeInterval = 30 * 24 * 60 * 60

    public static func delay(since last: Date?, now: Date, interval: TimeInterval = GeocodePace.minimumInterval) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, interval - now.timeIntervalSince(last))
    }

    public static func shouldRetryFailure(lookedUpAt: Date, now: Date, retry: TimeInterval = GeocodePace.failureRetry) -> Bool {
        now.timeIntervalSince(lookedUpAt) >= retry
    }
}

public enum GeoDistance {
    public static let earthRadiusKilometers = 6371.0

    public static func kilometers(
        latitude: Double,
        longitude: Double,
        otherLatitude: Double,
        otherLongitude: Double
    ) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = otherLatitude * .pi / 180
        let dLat = (otherLatitude - latitude) * .pi / 180
        let dLon = (otherLongitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return earthRadiusKilometers * c
    }
}

public struct PlaceLookup: Equatable, Sendable {
    public var cacheKey: String
    public var latitude: Double
    public var longitude: Double
    public var assetIDs: [String]

    public init(cacheKey: String, latitude: Double, longitude: Double, assetIDs: [String]) {
        self.cacheKey = cacheKey
        self.latitude = latitude
        self.longitude = longitude
        self.assetIDs = assetIDs
    }
}

public struct CachedPlace: Equatable, Sendable {
    public var key: String
    public var latitude: Double
    public var longitude: Double
    public var placeName: String?
    public var lookedUpAt: Date

    public init(key: String, latitude: Double, longitude: Double, placeName: String?, lookedUpAt: Date) {
        self.key = key
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.lookedUpAt = lookedUpAt
    }
}
