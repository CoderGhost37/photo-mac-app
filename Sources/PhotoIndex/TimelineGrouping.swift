import Foundation

/// How the library grid clusters photos. All Photos is one continuous grid.
public enum TimelineScale: String, CaseIterable, Sendable, Equatable {
    case years
    case months
    case days
    case all
}

public enum LibrarySort: String, CaseIterable, Sendable, Equatable {
    case newest
    case oldest
}

/// Photos added in this window count as Recents.
public enum RecentsWindow {
    public static let days = 30

    public static func start(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)
            ?? now.addingTimeInterval(-Double(days) * 86_400)
    }

    public static func contains(_ date: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        return date >= start(now: now, calendar: calendar) && date <= now.addingTimeInterval(1)
    }
}

public struct TimelineSection: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var place: String?
    public var assets: [Asset]

    public init(id: String, title: String, place: String?, assets: [Asset]) {
        self.id = id
        self.title = title
        self.place = place
        self.assets = assets
    }
}

public enum TimelineGrouping {
    public static func sections(
        assets: [Asset],
        scale: TimelineScale,
        sort: LibrarySort,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [TimelineSection] {
        let newestFirst = sort == .newest
        let ordered = assets.sorted { compare($0, $1, newestFirst: newestFirst) }
        if scale == .all {
            guard !ordered.isEmpty else { return [] }
            return [TimelineSection(id: "all", title: "", place: nil, assets: ordered)]
        }

        var buckets: [String: [Asset]] = [:]
        var keyOrder: [String] = []
        for asset in ordered {
            let key = sectionKey(for: asset.createdAt, scale: scale, calendar: calendar)
            if buckets[key] == nil {
                keyOrder.append(key)
            }
            buckets[key, default: []].append(asset)
        }

        let dated = keyOrder.filter { $0 != "undated" }.sorted { lhs, rhs in
            let left = anchor(buckets[lhs] ?? [], newestFirst: newestFirst)
            let right = anchor(buckets[rhs] ?? [], newestFirst: newestFirst)
            switch (left, right) {
            case let (l?, r?) where l != r:
                return newestFirst ? l > r : l < r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs < rhs
            }
        }
        var keys = dated
        if keyOrder.contains("undated") {
            keys.append("undated")
        }

        return keys.compactMap { key in
            guard let group = buckets[key], !group.isEmpty else { return nil }
            let sorted = group.sorted { compare($0, $1, newestFirst: newestFirst) }
            let sample = sorted.compactMap(\.createdAt).first
            return TimelineSection(
                id: key,
                title: title(for: sample, key: key, scale: scale, calendar: calendar, now: now),
                place: dominantPlace(in: sorted),
                assets: sorted
            )
        }
    }

    public static func displayPlace(for asset: Asset) -> String? {
        let stored = asset.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        let geocoded = asset.geocodedPlace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return geocoded.isEmpty ? nil : geocoded
    }

    public static func dominantPlace(in assets: [Asset]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for asset in assets {
            guard let place = displayPlace(for: asset) else { continue }
            if counts[place] == nil {
                order.append(place)
            }
            counts[place, default: 0] += 1
        }
        return order.max { lhs, rhs in
            (counts[lhs] ?? 0) < (counts[rhs] ?? 0)
        }
    }

    private static func anchor(_ assets: [Asset], newestFirst: Bool) -> Date? {
        let dates = assets.compactMap(\.createdAt)
        if newestFirst { return dates.max() }
        return dates.min()
    }

    private static func compare(_ lhs: Asset, _ rhs: Asset, newestFirst: Bool) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right:
            return newestFirst ? left > right : left < right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            return lhs.id < rhs.id
        }
    }

    private static func sectionKey(for date: Date?, scale: TimelineScale, calendar: Calendar) -> String {
        guard let date else { return "undated" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        switch scale {
        case .years:
            return "y-\(parts.year ?? 0)"
        case .months:
            return "m-\(parts.year ?? 0)-\(parts.month ?? 0)"
        case .days:
            return "d-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        case .all:
            return "all"
        }
    }

    private static func title(
        for date: Date?,
        key: String,
        scale: TimelineScale,
        calendar: Calendar,
        now: Date
    ) -> String {
        if key == "undated" || date == nil { return "No Date" }
        guard let date else { return "No Date" }
        switch scale {
        case .years:
            let year = calendar.component(.year, from: date)
            return "\(year)"
        case .months:
            return formatted(date, format: "MMMM yyyy", calendar: calendar)
        case .days:
            if calendar.isDate(date, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(date, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            return formatted(date, format: "d MMM yyyy", calendar: calendar)
        case .all:
            return ""
        }
    }

    private static func formatted(_ date: Date, format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
