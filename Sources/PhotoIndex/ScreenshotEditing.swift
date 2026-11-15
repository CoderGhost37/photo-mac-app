#if canImport(AppKit)
import AppKit
import CoreText
import ImageIO

public enum ScreenshotColor: String, CaseIterable, Equatable, Identifiable {
    case red, orange, yellow, green, blue, purple, black, white
    public var id: Self { self }
    public var cgColor: CGColor {
        switch self {
        case .red: CGColor(red: 0.95, green: 0.16, blue: 0.2, alpha: 1)
        case .orange: CGColor(red: 1, green: 0.5, blue: 0.08, alpha: 1)
        case .yellow: CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
        case .green: CGColor(red: 0.15, green: 0.7, blue: 0.35, alpha: 1)
        case .blue: CGColor(red: 0.12, green: 0.45, blue: 0.95, alpha: 1)
        case .purple: CGColor(red: 0.58, green: 0.3, blue: 0.9, alpha: 1)
        case .black: CGColor(gray: 0, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        }
    }
}

/// All editor coordinates are original image pixels measured from the top left.
public enum ScreenshotMark: Equatable {
    case arrow(from: CGPoint, to: CGPoint, width: CGFloat, color: ScreenshotColor = .red)
    case text(String, at: CGPoint, size: CGFloat, color: ScreenshotColor = .red)
    case redaction(CGRect)

    public var bounds: CGRect {
        switch self {
        case let .arrow(a, b, width, _):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -width / 2, dy: -width / 2)
        case let .text(text, point, size, _):
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return CGRect(origin: point, size: CGSize(width: max(size / 2, width), height: size * 1.25))
        case let .redaction(rect): return rect.standardized
        }
    }

    public var handles: [ScreenshotHandle: CGPoint] {
        switch self {
        case let .arrow(a, b, _, _): return [.start: a, .end: b]
        default:
            let r = bounds
            return [.topLeft: CGPoint(x: r.minX, y: r.minY), .topRight: CGPoint(x: r.maxX, y: r.minY),
                    .bottomLeft: CGPoint(x: r.minX, y: r.maxY), .bottomRight: CGPoint(x: r.maxX, y: r.maxY)]
        }
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch self {
        case let .arrow(a, b, width, _):
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= max(tolerance, width * 2)
        default: return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public func moved(by delta: CGSize, inside imageSize: CGSize) -> ScreenshotMark {
        guard delta != .zero else { return self }
        let r = bounds
        let dx = min(max(delta.width, -r.minX), max(-r.minX, imageSize.width - r.maxX))
        let dy = min(max(delta.height, -r.minY), max(-r.minY, imageSize.height - r.maxY))
        func offset(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        switch self {
        case let .arrow(a, b, width, color): return .arrow(from: offset(a), to: offset(b), width: width, color: color)
        case let .text(text, point, size, color): return .text(text, at: offset(point), size: size, color: color)
        case let .redaction(rect): return .redaction(rect.offsetBy(dx: dx, dy: dy))
        }
    }

    public func resized(handle: ScreenshotHandle, to point: CGPoint) -> ScreenshotMark {
        switch self {
        case let .arrow(a, b, width, color):
            return .arrow(from: handle == .start ? point : a, to: handle == .end ? point : b, width: width, color: color)
        default:
            let r = bounds
            let left = handle == .topLeft || handle == .bottomLeft
            let top = handle == .topLeft || handle == .topRight
            let anchor = CGPoint(x: left ? r.maxX : r.minX, y: top ? r.maxY : r.minY)
            let target = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: max(1, abs(point.x - anchor.x)), height: max(1, abs(point.y - anchor.y)))
            switch self {
            case .redaction: return .redaction(target)
            case let .text(text, _, size, color):
                let factor = max(0.1, max(target.width / r.width, target.height / r.height))
                let newSize = min(400, max(6, size * factor))
                let scaled = ScreenshotMark.text(text, at: .zero, size: newSize, color: color).bounds.size
                return .text(text, at: CGPoint(x: left ? anchor.x - scaled.width : anchor.x, y: top ? anchor.y - scaled.height : anchor.y), size: newSize, color: color)
            case .arrow: return self
            }
        }
    }
}

public enum ScreenshotHandle: String, CaseIterable, Identifiable {
    case start, end, topLeft, topRight, bottomLeft, bottomRight
    public var id: Self { self }
}

public struct ScreenshotAnnotation: Equatable, Identifiable {
    public let id: UUID
    public var mark: ScreenshotMark
    public init(id: UUID = UUID(), mark: ScreenshotMark) { self.id = id; self.mark = mark }
}

public enum ScreenshotBackgroundStyle: String, CaseIterable, Identifiable {
    case none, solid, gradient
    public var id: Self { self }
}

public struct ScreenshotBackground: Equatable {
    public var style: ScreenshotBackgroundStyle = .none
    public var color: ScreenshotColor = .purple
    public var secondColor: ScreenshotColor = .blue
    public var padding: CGFloat = 48
    public var cornerRadius: CGFloat = 16
    public var shadow = true
    public init() {}
}

public struct ScreenshotEditState: Equatable {
    public var annotations: [ScreenshotAnnotation] = []
    public var crop: CGRect?
    public var background = ScreenshotBackground()
    public init() {}
}

public struct ScreenshotEditHistory {
    public private(set) var undoStates: [ScreenshotEditState] = []
    public private(set) var redoStates: [ScreenshotEditState] = []
    public init() {}
    public mutating func record(_ previous: ScreenshotEditState, replacing next: ScreenshotEditState) {
        guard previous != next else { return }
        undoStates.append(previous)
        redoStates.removeAll()
    }
    public mutating func undo(_ current: ScreenshotEditState) -> ScreenshotEditState? {
        guard let previous = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return previous
    }
    public mutating func redo(_ current: ScreenshotEditState) -> ScreenshotEditState? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return next
    }
}

public enum ScreenshotEditing {
    public static func load(_ url: URL) throws -> CGImage {
        try StillImageReader.orientedImage(at: url)
    }

    public static func pixelPoint(_ point: CGPoint, displayedIn frame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(x: min(imageSize.width, max(0, (point.x - frame.minX) * imageSize.width / frame.width)),
                y: min(imageSize.height, max(0, (point.y - frame.minY) * imageSize.height / frame.height)))
    }

    public static func render(_ image: CGImage, marks: [ScreenshotMark], crop: CGRect? = nil, background: ScreenshotBackground = ScreenshotBackground()) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertFailure.exportFailed("There is not enough memory to edit this image.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: CGFloat(height) - p.y) }
        for mark in marks {
            context.saveGState()
            switch mark {
            case let .arrow(start, end, lineWidth, color):
                let a = flip(start), b = flip(end)
                context.setStrokeColor(color.cgColor)
                context.setFillColor(color.cgColor)
                context.setLineWidth(lineWidth)
                context.setLineCap(.round)
                context.move(to: a); context.addLine(to: b); context.strokePath()
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(12, lineWidth * 4)
                context.move(to: b)
                context.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6)))
                context.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6)))
                context.closePath(); context.fillPath()
            case let .text(text, point, size, color):
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
                let string = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
                ])
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: point.x, y: CGFloat(height) - point.y - size)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            case let .redaction(rect):
                // Pixel-aligned, opaque fill: no original pixels survive within the selected area.
                let r = rect.standardized.integral
                context.setShouldAntialias(false)
                context.setBlendMode(.copy)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
            }
            context.restoreGState()
        }
        guard let flattened = context.makeImage() else { throw ConvertFailure.exportFailed("Could not render this image.") }
        let cropped: CGImage
        if let crop {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let rect = crop.standardized.integral.intersection(bounds)
            guard rect.width >= 1, rect.height >= 1, let result = flattened.cropping(to: rect) else {
                throw ConvertFailure.exportFailed("Choose a crop inside the image.")
            }
            cropped = result
        } else { cropped = flattened }
        return try applyBackground(background, to: cropped)
    }

    private static func applyBackground(_ background: ScreenshotBackground, to image: CGImage) throws -> CGImage {
        guard background.style != .none else { return image }
        let padding = max(0, min(1000, background.padding)).rounded()
        let width = image.width + Int(padding) * 2, height = image.height + Int(padding) * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertFailure.exportFailed("There is not enough memory to add this background.")
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background.color.cgColor)
        context.fill(canvas)
        if background.style == .gradient,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [background.color.cgColor, background.secondColor.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }
        let imageRect = CGRect(x: padding, y: padding, width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = min(max(0, background.cornerRadius), min(imageRect.width, imageRect.height) / 2)
        let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if background.shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -padding / 6), blur: padding / 3, color: CGColor(gray: 0, alpha: 0.4))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.addPath(path)
        context.clip()
        context.draw(image, in: imageRect)
        guard let result = context.makeImage() else { throw ConvertFailure.exportFailed("Could not render the background.") }
        return result
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ConvertFailure.exportFailed("Could not prepare a PNG copy.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConvertFailure.exportFailed("Could not encode the PNG copy.") }
        return data as Data
    }

    /// The chosen name is a suggestion. Existing files and the source always get a new numbered name.
    public static func saveCopy(_ image: CGImage, suggestedURL: URL, originalURL: URL) throws -> URL {
        var reserved = Set<String>()
        let path = try OutputNamer.allocate(displayName: suggestedURL.lastPathComponent,
                                           sourcePath: originalURL.resolvingSymlinksInPath().path,
                                           fileExtension: "png", directory: suggestedURL.deletingLastPathComponent().path,
                                           reserved: &reserved, exists: { FileManager.default.fileExists(atPath: $0) }).get()
        let output = URL(fileURLWithPath: path)
        let data = try pngData(image)
        try data.write(to: output, options: .withoutOverwriting)
        return output
    }
}
#endif
