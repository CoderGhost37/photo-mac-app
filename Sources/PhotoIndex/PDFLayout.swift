import Foundation

public enum PDFPaper: String, CaseIterable, Sendable, Equatable, Identifiable {
    case a4
    case letter
    case fit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        case .fit: return "Fit"
        }
    }
}

public struct PDFPageLayout: Equatable, Sendable {
    public var pageWidth: Double
    public var pageHeight: Double
    public var imageX: Double
    public var imageY: Double
    public var imageWidth: Double
    public var imageHeight: Double

    public init(
        pageWidth: Double,
        pageHeight: Double,
        imageX: Double,
        imageY: Double,
        imageWidth: Double,
        imageHeight: Double
    ) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.imageX = imageX
        self.imageY = imageY
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

public enum PDFLayout {
    public static let pointsPerInch: Double = 72
    public static let a4Short: Double = 210.0 / 25.4 * pointsPerInch
    public static let a4Long: Double = 297.0 / 25.4 * pointsPerInch
    public static let letterShort: Double = 8.5 * pointsPerInch
    public static let letterLong: Double = 11 * pointsPerInch
    public static let margin: Double = 36
    /// Fit pages use this many image pixels per inch.
    public static let fitDPI: Double = 144
    /// Photos embedded on A4 or Letter are capped at this many pixels per point.
    public static let embedScale: Double = 2

    /// One image per page. Wide photos use a landscape A4 or Letter page. Fit has no margin.
    /// Returns nil when either pixel dimension is not positive.
    public static func layout(paper: PDFPaper, pixelWidth: Int, pixelHeight: Int) -> PDFPageLayout? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let px = Double(pixelWidth)
        let py = Double(pixelHeight)
        switch paper {
        case .fit:
            let scale = pointsPerInch / fitDPI
            return PDFPageLayout(
                pageWidth: px * scale,
                pageHeight: py * scale,
                imageX: 0,
                imageY: 0,
                imageWidth: px * scale,
                imageHeight: py * scale
            )
        case .a4, .letter:
            let short = paper == .a4 ? a4Short : letterShort
            let long = paper == .a4 ? a4Long : letterLong
            let landscape = px > py
            let pageWidth = landscape ? long : short
            let pageHeight = landscape ? short : long
            let contentWidth = pageWidth - margin * 2
            let contentHeight = pageHeight - margin * 2
            let scale = min(contentWidth / px, contentHeight / py)
            let imageWidth = px * scale
            let imageHeight = py * scale
            return PDFPageLayout(
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                imageX: (pageWidth - imageWidth) / 2,
                imageY: (pageHeight - imageHeight) / 2,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        }
    }

    /// Pixel size to embed. Does not enlarge a picture that is already smaller than the cap.
    public static func embedPixelSize(
        layout: PDFPageLayout,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> PixelSize? {
        guard sourceWidth > 0, sourceHeight > 0, layout.imageWidth > 0, layout.imageHeight > 0 else { return nil }
        let capWidth = max(1, Int((layout.imageWidth * embedScale).rounded()))
        let capHeight = max(1, Int((layout.imageHeight * embedScale).rounded()))
        let scale = min(1, Double(capWidth) / Double(sourceWidth), Double(capHeight) / Double(sourceHeight))
        return PixelSize(
            width: max(1, Int((Double(sourceWidth) * scale).rounded())),
            height: max(1, Int((Double(sourceHeight) * scale).rounded()))
        )
    }
}

public enum PDFPageOrder: String, CaseIterable, Sendable, Equatable, Identifiable {
    case listed
    case name
    case date

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .listed: return "Listed"
        case .name: return "Name"
        case .date: return "Date"
        }
    }
}

public struct PDFPageRef: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var date: Date?

    public init(id: String, name: String, date: Date?) {
        self.id = id
        self.name = name
        self.date = date
    }
}

public enum PDFPageOrdering {
    /// Date order is oldest first. Pages with no date stay at the end. Equal keys keep the original order.
    public static func ordered(_ items: [PDFPageRef], by order: PDFPageOrder) -> [PDFPageRef] {
        switch order {
        case .listed:
            return items
        case .name:
            return items.enumerated().sorted { a, b in
                let foldedA = fold(a.element.name)
                let foldedB = fold(b.element.name)
                if foldedA != foldedB { return foldedA < foldedB }
                return a.offset < b.offset
            }.map(\.element)
        case .date:
            return items.enumerated().sorted { a, b in
                switch (a.element.date, b.element.date) {
                case let (left?, right?) where left != right:
                    return left < right
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                default:
                    let foldedA = fold(a.element.name)
                    let foldedB = fold(b.element.name)
                    if foldedA != foldedB { return foldedA < foldedB }
                    return a.offset < b.offset
                }
            }.map(\.element)
        }
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Crop box in the image after rotation. Origin is the top left, values are fractions of the width and height.
public struct NormalizedRect: Equatable, Sendable {
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

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public func pixelRect(imageWidth: Int, imageHeight: Int) -> PixelRect? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let unit = clamped()
        var x = Int((unit.x * Double(imageWidth)).rounded(.down))
        var y = Int((unit.y * Double(imageHeight)).rounded(.down))
        var width = Int((unit.width * Double(imageWidth)).rounded())
        var height = Int((unit.height * Double(imageHeight)).rounded())
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x >= imageWidth { x = imageWidth - 1 }
        if y >= imageHeight { y = imageHeight - 1 }
        if x + width > imageWidth { width = imageWidth - x }
        if y + height > imageHeight { height = imageHeight - y }
        if width < 1 { width = 1 }
        if height < 1 { height = 1 }
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    public func clamped(minimumSpan: Double = 0.02) -> NormalizedRect {
        var x = min(max(self.x, 0), 1)
        var y = min(max(self.y, 0), 1)
        var width = min(max(self.width, 0), 1)
        var height = min(max(self.height, 0), 1)
        if x + width > 1 { width = 1 - x }
        if y + height > 1 { height = 1 - y }
        if width < minimumSpan {
            width = minimumSpan
            if x + width > 1 { x = 1 - width }
        }
        if height < minimumSpan {
            height = minimumSpan
            if y + height > 1 { y = 1 - height }
        }
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

/// Fractions cut off each edge, top-left origin, applied after rotation.
public struct CropInsets: Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double

    public init(left: Double, right: Double, top: Double, bottom: Double) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    public static let none = CropInsets(left: 0, right: 0, top: 0, bottom: 0)

    public func rect(minimumSpan: Double = 0.05) -> NormalizedRect {
        var left = clampUnit(self.left)
        var right = clampUnit(self.right)
        var top = clampUnit(self.top)
        var bottom = clampUnit(self.bottom)
        if left + right > 1 - minimumSpan {
            let share = (left + right - (1 - minimumSpan)) / 2
            left -= share
            right -= share
        }
        if top + bottom > 1 - minimumSpan {
            let share = (top + bottom - (1 - minimumSpan)) / 2
            top -= share
            bottom -= share
        }
        return NormalizedRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
    }

    private func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

public enum QuarterTurns: Int, CaseIterable, Sendable, Equatable {
    case none = 0
    case clockwise = 1
    case half = 2
    case counterClockwise = 3

    public var degrees: Int { rawValue * 90 }

    public var nextClockwise: QuarterTurns {
        QuarterTurns(rawValue: (rawValue + 1) % 4) ?? .none
    }

    public var nextCounterClockwise: QuarterTurns {
        QuarterTurns(rawValue: (rawValue + 3) % 4) ?? .none
    }

    public func size(width: Int, height: Int) -> PixelSize {
        switch self {
        case .none, .half:
            return PixelSize(width: width, height: height)
        case .clockwise, .counterClockwise:
            return PixelSize(width: height, height: width)
        }
    }
}

public enum ImageEditMath {
    /// Rotation is applied first. The crop is in that rotated image, origin at the top left.
    public static func outputSize(
        pixelWidth: Int,
        pixelHeight: Int,
        rotation: QuarterTurns,
        crop: NormalizedRect
    ) -> PixelSize? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let rotated = rotation.size(width: pixelWidth, height: pixelHeight)
        guard let rect = crop.pixelRect(imageWidth: rotated.width, imageHeight: rotated.height) else { return nil }
        return PixelSize(width: rect.width, height: rect.height)
    }
}

public enum PDFFailure: Error, Equatable, LocalizedError {
    case unreadable(String)
    case noPages
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Could not read \(name)."
        case .noPages:
            return "There is nothing to put in the PDF."
        case .writeFailed(let name):
            return "Could not write \(name)."
        }
    }
}

/// Frame times for a GIF made from a video. Times stay inside the clip and stop after a short window.
public enum GIFSampling {
    public static let maxFrames = 48
    public static let maxDuration = 8.0
    public static let framesPerSecond = 8.0
    public static let maxLongEdge = 640.0

    public static var frameDelay: Double { 1 / framesPerSecond }

    public static func plan(duration: Double) -> [Double] {
        let safe = duration.isFinite && duration > 0 ? duration : 0
        if safe <= 0 { return [0] }
        let window = min(safe, maxDuration)
        let step = 1 / framesPerSecond
        let end = max(0, window - 0.001)
        var times: [Double] = []
        var cursor = 0.0
        while times.count < maxFrames && cursor <= end + 0.000_000_1 {
            times.append(min(cursor, max(0, safe - 0.05)))
            cursor += step
        }
        return times.isEmpty ? [0] : times
    }
}
