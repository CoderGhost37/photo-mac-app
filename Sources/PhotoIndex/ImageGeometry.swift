import Foundation

public struct FittedRect: Equatable, Sendable {
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
}

public enum AspectFit {
    public static func rect(containerWidth: Double, containerHeight: Double, imageWidth: Double, imageHeight: Double) -> FittedRect? {
        guard containerWidth > 0, containerHeight > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let scale = min(containerWidth / imageWidth, containerHeight / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return FittedRect(
            x: (containerWidth - width) / 2,
            y: (containerHeight - height) / 2,
            width: width,
            height: height
        )
    }
}

public enum CenterSquare {
    /// A square crop using the existing pixel rectangle. The side is the shorter image edge.
    public static func crop(width: Int, height: Int) -> PixelRect? {
        guard width > 0, height > 0 else { return nil }
        let side = min(width, height)
        return PixelRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }
}
