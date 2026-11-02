import Foundation

public enum SubjectKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case person
    case cat
    case dog
}

public struct SubjectSample: Equatable, Sendable, Identifiable {
    public var id: String
    public var assetID: String
    public var kind: SubjectKind
    public var vector: [Float]

    public init(id: String, assetID: String, kind: SubjectKind, vector: [Float]) {
        self.id = id
        self.assetID = assetID
        self.kind = kind
        self.vector = vector
    }
}

public struct SubjectCluster: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: SubjectKind
    public var name: String
    public var memberIDs: [String]
    public var rejectedAssetIDs: [String]

    public init(
        id: String,
        kind: SubjectKind,
        name: String,
        memberIDs: [String],
        rejectedAssetIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.memberIDs = memberIDs
        self.rejectedAssetIDs = rejectedAssetIDs
    }
}

public struct SubjectClusterRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: SubjectKind
    public var name: String
    public var assetIDs: [String]
    public var coverAssetID: String?
    public var coverBox: NormalizedBox?

    public init(
        id: String,
        kind: SubjectKind,
        name: String,
        assetIDs: [String],
        coverAssetID: String? = nil,
        coverBox: NormalizedBox? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.assetIDs = assetIDs
        self.coverAssetID = coverAssetID
        self.coverBox = coverBox
    }

    public var count: Int { assetIDs.count }
}

/// Groups face and pet prints. Distance is cosine distance (1 - cosine): 0 is the same print.
/// Existing names, membership, and rejected photos are kept. Only new samples are assigned.
public enum SubjectGrouping {
    /// Face-crop prints at or under this cosine distance join a person.
    public static let personDistance = 0.35
    /// Pet crops at or under this cosine distance join a cat or a dog.
    public static let petDistance = 0.40

    public static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        1 - EmbeddingMath.cosine(lhs, rhs)
    }

    public static func assign(
        samples: [SubjectSample],
        clusters: [SubjectCluster],
        threshold: Double,
        newID: (SubjectKind) -> String
    ) -> [SubjectCluster] {
        let sampleByID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var clusters = clusters.compactMap { cluster -> SubjectCluster? in
            var copy = cluster
            copy.memberIDs = cluster.memberIDs.filter { sampleByID[$0]?.kind == cluster.kind }
            copy.rejectedAssetIDs = Array(Set(cluster.rejectedAssetIDs)).sorted()
            return copy.memberIDs.isEmpty ? nil : copy
        }

        let assigned = Set(clusters.flatMap(\.memberIDs))
        let pending = samples.filter { !assigned.contains($0.id) }.sorted { $0.id < $1.id }
        for sample in pending {
            var best: (index: Int, distance: Double)?
            for index in clusters.indices {
                let cluster = clusters[index]
                guard cluster.kind == sample.kind, !cluster.rejectedAssetIDs.contains(sample.assetID) else { continue }
                let members = cluster.memberIDs.compactMap { sampleByID[$0]?.vector }
                guard let centroid = mean(members) else { continue }
                let distance = cosineDistance(sample.vector, centroid)
                if let current = best {
                    let closer = distance < current.distance - 1e-9
                    let tie = abs(distance - current.distance) <= 1e-9 && cluster.id < clusters[current.index].id
                    if closer || tie { best = (index, distance) }
                } else {
                    best = (index, distance)
                }
            }
            if let best, best.distance <= threshold {
                if !clusters[best.index].memberIDs.contains(sample.id) {
                    clusters[best.index].memberIDs.append(sample.id)
                }
            } else {
                clusters.append(SubjectCluster(
                    id: freshID(kind: sample.kind, existing: clusters, newID: newID),
                    kind: sample.kind,
                    name: "",
                    memberIDs: [sample.id]
                ))
            }
        }
        return clusters.sorted { $0.id < $1.id }
    }

    public static func rename(_ clusters: [SubjectCluster], id: String, name: String) -> [SubjectCluster] {
        var clusters = clusters
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return clusters }
        clusters[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clusters
    }

    public static func merge(
        clusters: [SubjectCluster],
        samples: [SubjectSample],
        keeping keepID: String,
        absorbing absorbID: String
    ) -> [SubjectCluster] {
        guard keepID != absorbID,
              let keepIndex = clusters.firstIndex(where: { $0.id == keepID }),
              let absorbIndex = clusters.firstIndex(where: { $0.id == absorbID }),
              clusters[keepIndex].kind == clusters[absorbIndex].kind else { return clusters }
        let sampleAsset = Dictionary(samples.map { ($0.id, $0.assetID) }, uniquingKeysWith: { first, _ in first })
        var clusters = clusters
        var keep = clusters[keepIndex]
        let absorb = clusters[absorbIndex]
        if keep.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keep.name = absorb.name
        }
        var rejected = Set(keep.rejectedAssetIDs).union(absorb.rejectedAssetIDs)
        var members = keep.memberIDs
        for id in absorb.memberIDs where !members.contains(id) {
            if let assetID = sampleAsset[id], rejected.contains(assetID) { continue }
            members.append(id)
        }
        rejected.subtract(Set(members.compactMap { sampleAsset[$0] }))
        keep.memberIDs = members
        keep.rejectedAssetIDs = rejected.sorted()
        clusters[keepIndex] = keep
        clusters.removeAll { $0.id == absorbID }
        return clusters
    }

    public static func remove(
        assetID: String,
        from clusterID: String,
        clusters: [SubjectCluster],
        samples: [SubjectSample]
    ) -> [SubjectCluster] {
        guard let index = clusters.firstIndex(where: { $0.id == clusterID }) else { return clusters }
        let sampleAsset = Dictionary(samples.map { ($0.id, $0.assetID) }, uniquingKeysWith: { first, _ in first })
        var clusters = clusters
        var cluster = clusters[index]
        cluster.memberIDs.removeAll { sampleAsset[$0] == assetID }
        if !cluster.rejectedAssetIDs.contains(assetID) {
            cluster.rejectedAssetIDs.append(assetID)
            cluster.rejectedAssetIDs.sort()
        }
        if cluster.memberIDs.isEmpty {
            clusters.remove(at: index)
        } else {
            clusters[index] = cluster
        }
        return clusters
    }

    private static func freshID(kind: SubjectKind, existing: [SubjectCluster], newID: (SubjectKind) -> String) -> String {
        let used = Set(existing.map(\.id))
        var id = newID(kind)
        var tries = 0
        while used.contains(id) && tries < 4 {
            id = newID(kind)
            tries += 1
        }
        if used.contains(id) {
            id += ":\(existing.count)"
        }
        return id
    }

    private static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        guard vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var totals = [Double](repeating: 0, count: first.count)
        for vector in vectors {
            for index in vector.indices {
                totals[index] += Double(vector[index])
            }
        }
        let count = Double(vectors.count)
        return totals.map { Float($0 / count) }
    }
}
