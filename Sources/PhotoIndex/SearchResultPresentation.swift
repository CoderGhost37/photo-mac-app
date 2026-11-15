import Foundation

public enum SearchResultScope: Sendable {
    case all, photos, videos
}

public enum SearchResultOrder: Sendable {
    case relevance, newest, oldest

    public var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }
}

public enum SearchResultPresentation {
    public static func assets(_ assets: [Asset], scope: SearchResultScope, order: SearchResultOrder) -> [Asset] {
        let filtered = assets.filter { asset in
            switch scope {
            case .all: return true
            case .photos: return asset.mediaKind == .photo || asset.mediaKind == .screenshot
            case .videos: return asset.mediaKind == .video || asset.mediaKind == .screenRecording
            }
        }
        guard order != .relevance else { return filtered }
        return filtered.enumerated().sorted { lhs, rhs in
            let left = lhs.element.createdAt ?? .distantPast
            let right = rhs.element.createdAt ?? .distantPast
            if left == right { return lhs.offset < rhs.offset }
            return order == .newest ? left > right : left < right
        }.map(\.element)
    }
}
