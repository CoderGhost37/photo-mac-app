import Foundation

/// Per-session gate for screenshot events. File reads and retry scheduling belong to the caller.
public struct ScreenshotDetection: Sendable {
    public struct Observation: Equatable, Sendable {
        public var creationDate: Date
        public var modificationDate: Date
        public var byteCount: Int64
        public var isNativeScreenshot: Bool
        public var isReadableImage: Bool

        public init(creationDate: Date, modificationDate: Date, byteCount: Int64,
                    isNativeScreenshot: Bool, isReadableImage: Bool) {
            self.creationDate = creationDate
            self.modificationDate = modificationDate
            self.byteCount = byteCount
            self.isNativeScreenshot = isNativeScreenshot
            self.isReadableImage = isReadableImage
        }
    }

    public enum Decision: Equatable, Sendable {
        case retry
        case ignore
        case capture
    }

    private let startedAt: Date
    private var excluded: Set<String>
    private var previous: [String: Observation] = [:]

    public init(startedAt: Date, existingPaths: Set<String> = []) {
        self.startedAt = startedAt
        self.excluded = existingPaths
    }

    public mutating func ignore(path: String) {
        excluded.insert(path)
        previous.removeValue(forKey: path)
    }

    public mutating func observe(path: String, observation: Observation?) -> Decision {
        guard !excluded.contains(path) else { return .ignore }
        guard let observation else {
            previous.removeValue(forKey: path)
            return .retry
        }
        guard observation.creationDate >= startedAt,
              observation.modificationDate >= startedAt else {
            ignore(path: path)
            return .ignore
        }
        guard observation.isNativeScreenshot, observation.isReadableImage,
              observation.byteCount > 0 else {
            previous.removeValue(forKey: path)
            return .retry
        }
        guard previous[path] == observation else {
            previous[path] = observation
            return .retry
        }
        ignore(path: path)
        return .capture
    }
}
