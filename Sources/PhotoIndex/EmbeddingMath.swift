import Foundation

public struct EmbeddedAsset: Equatable, Sendable {
    public var id: String
    public var values: [Float]

    public init(id: String, values: [Float]) {
        self.id = id
        self.values = values
    }
}

public struct VectorScore: Equatable, Sendable {
    public var id: String
    public var cosine: Double

    public init(id: String, cosine: Double) {
        self.id = id
        self.cosine = cosine
    }
}

public enum EmbeddingMath {
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var left = 0.0
        var right = 0.0
        for index in lhs.indices {
            let a = Double(lhs[index])
            let b = Double(rhs[index])
            dot += a * b
            left += a * a
            right += b * b
        }
        guard left > 0, right > 0 else { return 0 }
        return dot / (left.squareRoot() * right.squareRoot())
    }

    /// Highest cosine first. Equal scores keep the smaller id first so the order is stable.
    public static func topK(query: [Float], corpus: [EmbeddedAsset], k: Int) -> [VectorScore] {
        guard k > 0, !query.isEmpty else { return [] }
        var scored: [VectorScore] = []
        scored.reserveCapacity(corpus.count)
        for item in corpus {
            scored.append(VectorScore(id: item.id, cosine: cosine(query, item.values)))
        }
        scored.sort { lhs, rhs in
            if lhs.cosine != rhs.cosine { return lhs.cosine > rhs.cosine }
            return lhs.id < rhs.id
        }
        if scored.count <= k { return scored }
        return Array(scored.prefix(k))
    }

    public static func unitLength(_ values: [Float]) -> [Float] {
        var sum = 0.0
        for value in values {
            sum += Double(value) * Double(value)
        }
        let norm = sum.squareRoot()
        guard norm > 0 else { return values }
        return values.map { Float(Double($0) / norm) }
    }

    /// Picks the row at the end-of-text token from a `[rows, dimension]` sequence and normalizes it.
    /// A vector that is already `dimension` long is normalized as-is.
    public static func pooledText(sequence: [Float], tokens: [Int32], endOfText: Int32, dimension: Int) -> [Float]? {
        guard dimension > 0, !sequence.isEmpty else { return nil }
        if sequence.count == dimension {
            return unitLength(sequence)
        }
        guard sequence.count.isMultiple(of: dimension) else { return nil }
        let rows = sequence.count / dimension
        guard let index = tokens.firstIndex(of: endOfText), index < rows else { return nil }
        let start = index * dimension
        return unitLength(Array(sequence[start..<(start + dimension)]))
    }
}

public enum VectorBlob {
    public static func pack(_ values: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpack(_ data: Data) -> [Float]? {
        guard data.count.isMultiple(of: 4) else { return nil }
        if data.isEmpty { return [] }
        return data.withUnsafeBytes { raw in
            let count = data.count / 4
            var values: [Float] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
                values.append(Float(bitPattern: bits))
            }
            return values
        }
    }
}
