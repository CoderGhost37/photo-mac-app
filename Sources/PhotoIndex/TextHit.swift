import Foundation

/// A rectangle in a unit square. Vision reports boxes with a lower-left origin.
public struct NormalizedBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The same box with a top-left origin, which is what the preview overlay uses.
    public func flippedVertically() -> NormalizedBox {
        NormalizedBox(x: x, y: 1 - y - height, width: width, height: height)
    }

    public func clamped() -> NormalizedBox {
        let originX = min(max(x, 0), 1)
        let originY = min(max(y, 0), 1)
        return NormalizedBox(
            x: originX,
            y: originY,
            width: min(max(width, 0), 1 - originX),
            height: min(max(height, 0), 1 - originY)
        )
    }
}

/// One line of text found in a picture, before it is stored.
public struct TextObservation: Equatable, Sendable {
    public var text: String
    public var box: NormalizedBox
    public var confidence: Double

    public init(text: String, box: NormalizedBox, confidence: Double) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// Stored text for one indexed asset. `box` uses Vision's lower-left origin.
public struct TextHit: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var assetID: String
    public var text: String
    public var box: NormalizedBox
    public var confidence: Double

    public init(id: Int64, assetID: String, text: String, box: NormalizedBox, confidence: Double) {
        self.id = id
        self.assetID = assetID
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}
