import Foundation

/// Why an asset matched the words in the query. Scores are assigned in `SearchRanker`.
public struct SearchEvidence: Equatable, Sendable {
    public var assetID: String
    /// Sum of per-token OCR ranks. Zero when the words were not read from the picture.
    public var ocr: Double
    public var filename: Bool
    public var place: Bool
    public var dateWords: Bool
    public var inDateRange: Bool
    /// The words were found, split across fields, and no single field has all of them.
    public var combinedFields: Bool

    public init(
        assetID: String,
        ocr: Double = 0,
        filename: Bool = false,
        place: Bool = false,
        dateWords: Bool = false,
        inDateRange: Bool = false,
        combinedFields: Bool = false
    ) {
        self.assetID = assetID
        self.ocr = ocr
        self.filename = filename
        self.place = place
        self.dateWords = dateWords
        self.inDateRange = inDateRange
        self.combinedFields = combinedFields
    }
}

public struct RankedScore: Equatable, Sendable {
    public var assetID: String
    public var textScore: Double
    public var semanticScore: Double
    public var score: Double

    public init(assetID: String, textScore: Double, semanticScore: Double, score: Double) {
        self.assetID = assetID
        self.textScore = textScore
        self.semanticScore = semanticScore
        self.score = score
    }
}

public struct RankedAsset: Equatable, Sendable {
    public var asset: Asset
    public var textScore: Double
    public var semanticScore: Double
    public var score: Double

    public init(asset: Asset, textScore: Double, semanticScore: Double, score: Double) {
        self.asset = asset
        self.textScore = textScore
        self.semanticScore = semanticScore
        self.score = score
    }
}

public enum SearchRanker {
    public static let defaultTextWeight = 0.6
    public static let defaultSemanticWeight = 0.4
    /// Cosines at or below this are treated as no match. CLIP similarities for a real hit sit above it.
    public static let semanticFloor = 0.15
    public static let resultLimit = 1000
    public static let semanticNeighbors = 100

    public static func textScores(_ rows: [SearchEvidence]) -> [String: Double] {
        let bestOCR = rows.map(\.ocr).max() ?? 0
        var scores: [String: Double] = [:]
        for row in rows {
            let score = textScore(row, bestOCR: bestOCR)
            if score > 0 {
                scores[row.assetID] = score
            }
        }
        return scores
    }

    /// OCR is scaled against the best OCR hit in the same result set. A full file-name match is 0.92,
    /// a place match is 0.80, and a date match is 0.70. Extra signals add 0.04 each, capped at 1.
    public static func textScore(_ evidence: SearchEvidence, bestOCR: Double) -> Double {
        var signals: [Double] = []
        if evidence.ocr > 0, bestOCR > 0 {
            signals.append(min(1, evidence.ocr / bestOCR))
        }
        if evidence.filename { signals.append(0.92) }
        if evidence.place { signals.append(0.80) }
        if evidence.dateWords || evidence.inDateRange { signals.append(0.70) }
        if signals.isEmpty, evidence.combinedFields { signals.append(0.64) }
        guard let best = signals.max() else { return 0 }
        return min(1, best + 0.04 * Double(signals.count - 1))
    }

    public static func semanticUnit(cosine: Double) -> Double {
        guard cosine.isFinite, cosine > semanticFloor else { return 0 }
        return min(1, (cosine - semanticFloor) / (1 - semanticFloor))
    }

    public static func blend(text: Double, semantic: Double, textWeight: Double, semanticWeight: Double) -> Double {
        let textPart = max(0, text)
        let semanticPart = max(0, semantic)
        let weightSum = max(0, textWeight) + max(0, semanticWeight)
        guard weightSum > 0 else { return 0 }
        return (textPart * max(0, textWeight) + semanticPart * max(0, semanticWeight)) / weightSum
    }

    public static func rank(
        textScores: [String: Double],
        semanticScores: [String: Double],
        textWeight: Double = defaultTextWeight,
        semanticWeight: Double = defaultSemanticWeight,
        limit: Int
    ) -> [RankedScore] {
        guard limit > 0 else { return [] }
        let ids = Set(textScores.keys).union(semanticScores.keys)
        var ranked: [RankedScore] = []
        ranked.reserveCapacity(ids.count)
        for id in ids {
            let text = textScores[id] ?? 0
            let semantic = semanticScores[id] ?? 0
            let score = blend(text: text, semantic: semantic, textWeight: textWeight, semanticWeight: semanticWeight)
            guard score > 0 else { continue }
            ranked.append(RankedScore(assetID: id, textScore: text, semanticScore: semantic, score: score))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.assetID < rhs.assetID
        }
        if ranked.count <= limit { return ranked }
        return Array(ranked.prefix(limit))
    }
}
