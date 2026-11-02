import Foundation

public enum DuplicateKind: String, Equatable, Sendable {
    case exact
    case near
}

public struct DuplicateCandidate: Equatable, Sendable, Identifiable {
    public var id: String
    public var contentHash: String?
    public var vector: [Float]?

    public init(id: String, contentHash: String?, vector: [Float]? = nil) {
        self.id = id
        self.contentHash = contentHash
        self.vector = vector
    }
}

public struct DuplicateGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: DuplicateKind
    public var assetIDs: [String]

    public init(id: String, kind: DuplicateKind, assetIDs: [String]) {
        self.id = id
        self.kind = kind
        self.assetIDs = assetIDs
    }

    public var count: Int { assetIDs.count }
}

public enum FeatureDistance {
    /// Euclidean distance between L2-normalized prints. 0 is an identical direction.
    /// A zero vector has no direction and returns nil.
    public static func unitEuclidean(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        let left = EmbeddingMath.unitLength(lhs)
        let right = EmbeddingMath.unitLength(rhs)
        var leftNorm = 0.0
        var sum = 0.0
        for index in left.indices {
            let a = Double(left[index])
            leftNorm += a * a
            let delta = a - Double(right[index])
            sum += delta * delta
        }
        guard leftNorm > 0 else { return nil }
        return sum.squareRoot()
    }
}

/// Exact copies share a content hash. Similar photos are linked when their
/// normalized feature prints are within `nearDuplicateDistance`, except pairs
/// that are already the same hash. Linking is transitive.
public enum DuplicateGrouping {
    /// 0.45 on unit prints is a cosine of about 0.90.
    public static let nearDuplicateDistance = 0.45

    public static func groups(
        _ items: [DuplicateCandidate],
        nearThreshold: Double = DuplicateGrouping.nearDuplicateDistance
    ) -> [DuplicateGroup] {
        var exactBuckets: [String: [String]] = [:]
        for item in items {
            let hash = item.contentHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !hash.isEmpty else { continue }
            exactBuckets[hash, default: []].append(item.id)
        }
        var exact: [DuplicateGroup] = []
        for (hash, ids) in exactBuckets where Set(ids).count >= 2 {
            let unique = Array(Set(ids)).sorted()
            exact.append(DuplicateGroup(id: "exact:\(hash)", kind: .exact, assetIDs: unique))
        }
        exact.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.id < rhs.id
        }

        let printable = items.filter { $0.vector != nil }
        var parent: [String: String] = [:]
        for item in printable {
            parent[item.id] = item.id
        }
        func find(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current {
                current = next
            }
            var compress = id
            while let next = parent[compress], next != current {
                parent[compress] = current
                compress = next
            }
            return current
        }
        func union(_ lhs: String, _ rhs: String) {
            let left = find(lhs)
            let right = find(rhs)
            if left == right { return }
            if left < right {
                parent[right] = left
            } else {
                parent[left] = right
            }
        }

        let indexed = printable.sorted { $0.id < $1.id }
        if nearThreshold >= 0 {
            for leftIndex in indexed.indices {
                for rightIndex in indexed.indices where rightIndex > leftIndex {
                    let left = indexed[leftIndex]
                    let right = indexed[rightIndex]
                    if sameHash(left.contentHash, right.contentHash) { continue }
                    guard let leftVector = left.vector, let rightVector = right.vector,
                          let distance = FeatureDistance.unitEuclidean(leftVector, rightVector),
                          distance <= nearThreshold else { continue }
                    union(left.id, right.id)
                }
            }
        }

        var components: [String: [String]] = [:]
        for item in printable {
            components[find(item.id), default: []].append(item.id)
        }
        var near: [DuplicateGroup] = []
        for (root, ids) in components where Set(ids).count >= 2 {
            let unique = Array(Set(ids)).sorted()
            near.append(DuplicateGroup(id: "near:\(root)", kind: .near, assetIDs: unique))
        }
        near.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.id < rhs.id
        }
        return exact + near
    }

    private static func sameHash(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !left.isEmpty && left == right
    }
}
