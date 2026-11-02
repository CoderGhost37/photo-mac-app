import Foundation

public struct MemoryAsset: Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var placeName: String?
    public var personIDs: [String]
    public var petIDs: [String]
    public var labels: [String]
    public var foodScore: Double?

    public init(
        id: String,
        createdAt: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        placeName: String? = nil,
        personIDs: [String] = [],
        petIDs: [String] = [],
        labels: [String] = [],
        foodScore: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.personIDs = personIDs
        self.petIDs = petIDs
        self.labels = labels
        self.foodScore = foodScore
    }
}

public enum HighlightKind: String, Equatable, Sendable {
    case forYou
    case onThisDay
    case yearsAgo
    case recentDay
    case trip
    case person
    case pet
    case food
    case roulette
}

public struct HighlightStory: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: HighlightKind
    public var title: String
    public var assetIDs: [String]

    public init(id: String, kind: HighlightKind, title: String, assetIDs: [String]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.assetIDs = assetIDs
    }

    public var count: Int { assetIDs.count }
}

public enum FoodLabels {
    public static let words: Set<String> = [
        "food", "meal", "dish", "pizza", "burger", "cake", "bread", "pasta", "salad",
        "dessert", "fruit", "breakfast", "lunch", "dinner", "coffee", "sushi",
        "sandwich", "soup", "steak", "cheese", "cookie", "pie", "noodle", "noodles",
        "rice", "wine", "beer", "taco", "curry", "pancake", "waffle", "donut",
        "doughnut", "pastry", "chocolate", "icecream"
    ]

    public static func matches(_ labels: [String]) -> Bool {
        for label in labels {
            let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            if folded.contains("ice cream") || folded.contains("hot dog") || folded.contains("hotdog") {
                return true
            }
            let tokens = folded.split { !$0.isLetter }.map(String.init)
            if tokens.contains(where: { words.contains($0) }) {
                return true
            }
        }
        return false
    }
}

public enum HighlightRules {
    public static let tripHomeCellDegrees = 0.5
    public static let tripMaxGap: TimeInterval = 36 * 60 * 60
    public static let tripRadiusKilometers = 80.0
    public static let tripMinimumPhotos = 3
    public static let recentDayWindow = 14
    public static let recentDayLimit = 8
    public static let personMinimumPhotos = 3
    public static let foodMinimumPhotos = 3
    public static let foodScoreThreshold = 0.30
    public static let forYouMinimum = 3
    public static let storyAssetLimit = 40
    public static let roulettePreferredAge: TimeInterval = 30 * 24 * 60 * 60

    public static func stories(
        assets: [MemoryAsset],
        names: [String: String] = [:],
        now: Date,
        calendar: Calendar
    ) -> [HighlightStory] {
        let onThisDayAssets = anniversary(assets, now: now, calendar: calendar)
        let onThisDay = onThisDayAssets.isEmpty ? nil : HighlightStory(
            id: "on-this-day",
            kind: .onThisDay,
            title: "On this day",
            assetIDs: capped(newestFirst(onThisDayAssets).map(\.id))
        )
        let yearStories = yearsAgo(onThisDayAssets, now: now, calendar: calendar)
        let recent = recentDays(assets, now: now, calendar: calendar)
        let trips = tripStories(assets)
        let people = subjectStories(assets, keyPath: \.personIDs, kind: .person, names: names, fallback: "Unnamed person")
        let pets = subjectStories(assets, keyPath: \.petIDs, kind: .pet, names: names, fallback: "Unnamed pet")
        let foodAssets = assets.filter { isFood($0) }
        let food = foodAssets.count >= foodMinimumPhotos ? HighlightStory(
            id: "food",
            kind: .food,
            title: "Food",
            assetIDs: capped(newestFirst(foodAssets).map(\.id))
        ) : nil
        let forYou = forYouStory(
            assets: assets,
            onThisDay: onThisDay,
            trips: trips,
            people: people,
            pets: pets,
            food: food
        )

        var result: [HighlightStory] = []
        if let forYou { result.append(forYou) }
        if let onThisDay { result.append(onThisDay) }
        result.append(contentsOf: yearStories)
        result.append(contentsOf: recent)
        result.append(contentsOf: trips)
        result.append(contentsOf: people)
        result.append(contentsOf: pets)
        if let food { result.append(food) }
        return result
    }

    /// A seeded shuffle. Photos older than 30 days are used when any exist.
    public static func roulette(
        assets: [MemoryAsset],
        count: Int,
        seed: UInt64,
        now: Date,
        calendar: Calendar = .current
    ) -> HighlightStory? {
        guard count > 0, !assets.isEmpty else { return nil }
        _ = calendar
        let cutoff = now.addingTimeInterval(-roulettePreferredAge)
        let older = assets.filter { asset in
            guard let created = asset.createdAt else { return false }
            return created < cutoff
        }
        let pool = older.isEmpty ? assets : older
        var generator = SeededGenerator(state: seed == 0 ? 0x9E3779B97F4A7C15 : seed)
        var shuffled = pool
        if shuffled.count > 1 {
            for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
                let swap = Int(generator.next() % UInt64(index + 1))
                shuffled.swapAt(index, swap)
            }
        }
        let ids = shuffled.prefix(count).map(\.id)
        guard !ids.isEmpty else { return nil }
        return HighlightStory(id: "roulette", kind: .roulette, title: "A memory", assetIDs: Array(ids))
    }

    public static func isFood(_ asset: MemoryAsset) -> Bool {
        if FoodLabels.matches(asset.labels) { return true }
        if let score = asset.foodScore, score >= foodScoreThreshold { return true }
        return false
    }

    private static func forYouStory(
        assets: [MemoryAsset],
        onThisDay: HighlightStory?,
        trips: [HighlightStory],
        people: [HighlightStory],
        pets: [HighlightStory],
        food: HighlightStory?
    ) -> HighlightStory? {
        var ids: [String] = []
        func take(_ story: HighlightStory?, limit: Int) {
            guard let story else { return }
            for id in story.assetIDs.prefix(limit) where !ids.contains(id) {
                ids.append(id)
                if ids.count >= 20 { return }
            }
        }
        take(onThisDay, limit: 5)
        take(trips.max { $0.count < $1.count }, limit: 5)
        take(people.max { $0.count < $1.count }, limit: 5)
        take(pets.max { $0.count < $1.count }, limit: 5)
        take(food, limit: 5)
        if ids.count < 8 {
            for asset in newestFirst(assets) where !ids.contains(asset.id) {
                ids.append(asset.id)
                if ids.count >= 12 { break }
            }
        }
        guard ids.count >= forYouMinimum else { return nil }
        return HighlightStory(id: "for-you", kind: .forYou, title: "For you", assetIDs: ids)
    }

    private static func anniversary(_ assets: [MemoryAsset], now: Date, calendar: Calendar) -> [MemoryAsset] {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year, let month = today.month, let day = today.day else { return [] }
        return assets.filter { asset in
            guard let created = asset.createdAt else { return false }
            let parts = calendar.dateComponents([.year, .month, .day], from: created)
            return parts.month == month && parts.day == day && (parts.year ?? year) < year
        }
    }

    private static func yearsAgo(_ assets: [MemoryAsset], now: Date, calendar: Calendar) -> [HighlightStory] {
        let year = calendar.component(.year, from: now)
        var byYear: [Int: [MemoryAsset]] = [:]
        for asset in assets {
            guard let created = asset.createdAt else { continue }
            let assetYear = calendar.component(.year, from: created)
            guard assetYear < year else { continue }
            byYear[assetYear, default: []].append(asset)
        }
        return byYear.keys.sorted(by: >).prefix(8).map { assetYear in
            let gap = year - assetYear
            let title = gap == 1 ? "1 year ago" : "\(gap) years ago"
            return HighlightStory(
                id: "years-\(assetYear)",
                kind: .yearsAgo,
                title: title,
                assetIDs: capped(newestFirst(byYear[assetYear] ?? []).map(\.id))
            )
        }
    }

    private static func recentDays(_ assets: [MemoryAsset], now: Date, calendar: Calendar) -> [HighlightStory] {
        let today = calendar.startOfDay(for: now)
        var stories: [HighlightStory] = []
        for offset in 0..<recentDayWindow {
            if stories.count >= recentDayLimit { break }
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let matching = assets.filter { asset in
                guard let created = asset.createdAt else { return false }
                return calendar.isDate(created, inSameDayAs: day)
            }
            guard !matching.isEmpty else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            stories.append(HighlightStory(
                id: "day-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)",
                kind: .recentDay,
                title: dayTitle(day, now: now, calendar: calendar),
                assetIDs: capped(newestFirst(matching).map(\.id))
            ))
        }
        return stories
    }

    private static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: day)
    }

    private static func tripStories(_ assets: [MemoryAsset]) -> [HighlightStory] {
        let located = assets.compactMap { asset -> (MemoryAsset, String)? in
            guard let latitude = asset.latitude, let longitude = asset.longitude,
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  asset.createdAt != nil else { return nil }
            let key = cellKey(latitude: latitude, longitude: longitude, degrees: tripHomeCellDegrees)
            return (asset, key)
        }
        guard !located.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for item in located {
            counts[item.1, default: 0] += 1
        }
        guard let home = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        })?.key else { return [] }

        let away = located
            .filter { $0.1 != home }
            .map(\.0)
            .sorted { lhs, rhs in
                let left = lhs.createdAt ?? .distantPast
                let right = rhs.createdAt ?? .distantPast
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
        var runs: [[MemoryAsset]] = []
        var current: [MemoryAsset] = []
        for asset in away {
            if let last = current.last, let start = current.first,
               let previous = last.createdAt, let created = asset.createdAt,
               let startLat = start.latitude, let startLon = start.longitude,
               let lat = asset.latitude, let lon = asset.longitude,
               created.timeIntervalSince(previous) <= tripMaxGap,
               GeoDistance.kilometers(latitude: startLat, longitude: startLon, otherLatitude: lat, otherLongitude: lon) <= tripRadiusKilometers {
                current.append(asset)
            } else {
                if current.count >= tripMinimumPhotos { runs.append(current) }
                current = [asset]
            }
        }
        if current.count >= tripMinimumPhotos { runs.append(current) }

        return runs.sorted { lhs, rhs in
            let left = lhs.first?.createdAt ?? .distantPast
            let right = rhs.first?.createdAt ?? .distantPast
            if left != right { return left > right }
            return (lhs.first?.id ?? "") < (rhs.first?.id ?? "")
        }.map { run in
            let ordered = newestFirst(run)
            let start = run.first?.id ?? ordered.first?.id ?? "trip"
            return HighlightStory(
                id: "trip:\(start)",
                kind: .trip,
                title: tripTitle(run),
                assetIDs: capped(ordered.map(\.id))
            )
        }
    }

    private static func tripTitle(_ run: [MemoryAsset]) -> String {
        var counts: [String: Int] = [:]
        for asset in run {
            guard let name = asset.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        if let best = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        })?.key {
            return best
        }
        return "Trip"
    }

    private static func subjectStories(
        _ assets: [MemoryAsset],
        keyPath: KeyPath<MemoryAsset, [String]>,
        kind: HighlightKind,
        names: [String: String],
        fallback: String
    ) -> [HighlightStory] {
        var grouped: [String: [MemoryAsset]] = [:]
        for asset in assets {
            for id in asset[keyPath: keyPath] where !id.isEmpty {
                grouped[id, default: []].append(asset)
            }
        }
        let ranked = grouped.map { id, members -> (String, [MemoryAsset]) in
            var seen = Set<String>()
            let unique = members.filter { seen.insert($0.id).inserted }
            return (id, unique)
        }
        .filter { $0.1.count >= personMinimumPhotos }
        .sorted { lhs, rhs in
            if lhs.1.count != rhs.1.count { return lhs.1.count > rhs.1.count }
            return lhs.0 < rhs.0
        }
        return ranked.prefix(8).map { id, members in
            let raw = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = raw.isEmpty ? fallback : raw
            return HighlightStory(
                id: "\(kind.rawValue):\(id)",
                kind: kind,
                title: title,
                assetIDs: capped(newestFirst(members).map(\.id))
            )
        }
    }

    private static func cellKey(latitude: Double, longitude: Double, degrees: Double) -> String {
        let lat = Int(floor(latitude / degrees))
        let lon = Int(floor(longitude / degrees))
        return "\(lat):\(lon)"
    }

    private static func newestFirst(_ assets: [MemoryAsset]) -> [MemoryAsset] {
        assets.sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs.id < rhs.id
            }
        }
    }

    private static func capped(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
            if result.count >= storyAssetLimit { break }
        }
        return result
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
