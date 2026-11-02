import Foundation

public struct GeoPoint: Equatable, Sendable, Identifiable {
    public var id: String
    public var latitude: Double
    public var longitude: Double

    public init(id: String, latitude: Double, longitude: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct MapCluster: Equatable, Sendable, Identifiable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var memberIDs: [String]

    public init(id: String, latitude: Double, longitude: Double, memberIDs: [String]) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.memberIDs = memberIDs
    }

    public var count: Int { memberIDs.count }
}

public struct MapSpan: Equatable, Sendable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

/// Grid clustering for a map. A wider visible span uses larger cells, so nearby
/// photos share a marker. Zooming in shrinks the cells and the marker splits.
public enum MapGrid {
    public static let divisions = 6

    public static func cellSize(latitudeSpan: Double, longitudeSpan: Double, divisions: Int = MapGrid.divisions) -> (latitude: Double, longitude: Double) {
        let parts = Double(max(divisions, 1))
        return (max(latitudeSpan, 0) / parts, max(longitudeSpan, 0) / parts)
    }

    public static func cluster(_ points: [GeoPoint], latitudeSpan: Double, longitudeSpan: Double, divisions: Int = MapGrid.divisions) -> [MapCluster] {
        let cell = cellSize(latitudeSpan: latitudeSpan, longitudeSpan: longitudeSpan, divisions: divisions)
        return cluster(points, latitudeCell: cell.latitude, longitudeCell: cell.longitude)
    }

    public static func cluster(_ points: [GeoPoint], latitudeCell: Double, longitudeCell: Double) -> [MapCluster] {
        let valid = points.filter(\.isValid)
        guard !valid.isEmpty else { return [] }
        if latitudeCell <= 0 || longitudeCell <= 0 {
            return valid.map { point in
                MapCluster(id: point.id, latitude: point.latitude, longitude: point.longitude, memberIDs: [point.id])
            }.sorted(by: sortClusters)
        }

        struct Bin {
            var latitude: Double
            var longitude: Double
            var ids: [String]
        }
        var bins: [String: Bin] = [:]
        for point in valid {
            let latIndex = Int(floor(point.latitude / latitudeCell))
            let lonIndex = Int(floor((point.longitude + 180) / longitudeCell))
            let key = "\(latIndex):\(lonIndex)"
            var bin = bins[key] ?? Bin(latitude: 0, longitude: 0, ids: [])
            bin.latitude += point.latitude
            bin.longitude += point.longitude
            bin.ids.append(point.id)
            bins[key] = bin
        }
        return bins.map { key, bin in
            let count = Double(bin.ids.count)
            return MapCluster(
                id: key,
                latitude: bin.latitude / count,
                longitude: bin.longitude / count,
                memberIDs: bin.ids.sorted()
            )
        }.sorted(by: sortClusters)
    }

    /// A region that contains every valid point, with a little padding.
    /// One point still gets a neighborhood instead of a zero span.
    public static func fittingSpan(for points: [GeoPoint]) -> MapSpan? {
        let valid = points.filter(\.isValid)
        guard let first = valid.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for point in valid.dropFirst() {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        let rawLat = max(maxLat - minLat, 0.4)
        let rawLon = max(maxLon - minLon, 0.4)
        let latitudeDelta = min(rawLat * 1.4, 160)
        var longitudeDelta = min(rawLon * 1.4, 360)
        if maxLon - minLon > 180 {
            longitudeDelta = 360
        }
        return MapSpan(
            centerLatitude: (minLat + maxLat) / 2,
            centerLongitude: (minLon + maxLon) / 2,
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    private static func sortClusters(_ lhs: MapCluster, _ rhs: MapCluster) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.id < rhs.id
    }
}
