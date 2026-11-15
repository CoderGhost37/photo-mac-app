import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

public enum ScreenshotStitching {
    public enum Failure: LocalizedError, Equatable {
        case unreadable
        case dimensions
        case limit
        case duplicate
        case uncertainOverlap
        case tooFewFrames

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "This frame could not be read as an image."
            case .dimensions: return "Every frame must have the same pixel dimensions. Keep the capture region and display scale unchanged."
            case .limit: return "This capture exceeds the image limit. Finish this capture and start another."
            case .duplicate: return "This frame repeats the previous frame. Scroll down before capturing the next frame."
            case .uncertainOverlap: return "A unique overlap could not be found. Keep at least 25% of the previous frame visible, avoid fixed headers and scroll bars, and try again."
            case .tooFewFrames: return "Capture at least two overlapping frames before finishing."
            }
        }
    }

    public struct Frame: Sendable {
        public let url: URL
        public let overlap: Int
    }

    /// Stores file references and one narrow pixel sample, rather than every decoded frame.
    public struct Session: Sendable {
        public private(set) var frames: [Frame] = []
        public private(set) var width = 0
        public private(set) var frameHeight = 0
        public private(set) var height = 0
        public let maximumHeight: Int
        public let maximumPixels: Int
        private var previousSample: [UInt8] = []
        private static let sampleWidth = 48

        public init(maximumHeight: Int = 30_000, maximumPixels: Int = 40_000_000) {
            self.maximumHeight = min(30_000, max(1, maximumHeight))
            self.maximumPixels = min(40_000_000, max(1, maximumPixels))
        }

        public mutating func append(_ url: URL) throws {
            try Task.checkCancellation()
            let image = try loadBounded(url)
            if !frames.isEmpty, image.width != width || image.height != frameHeight { throw Failure.dimensions }
            let sample = try Self.sample(image)
            let overlap = frames.isEmpty ? 0 : try Self.overlap(previousSample, sample, height: image.height)
            if let previous = frames.last {
                let previousImage = try loadBounded(previous.url)
                guard try Self.matchesFullOverlap(previousImage, image, overlap: overlap) else { throw Failure.uncertainOverlap }
            }
            let nextHeight = height + image.height - overlap
            guard nextHeight <= maximumHeight, image.width <= maximumPixels / nextHeight else { throw Failure.limit }
            width = image.width
            frameHeight = image.height
            height = nextHeight
            frames.append(Frame(url: url, overlap: overlap))
            previousSample = sample
        }

        public func render() throws -> CGImage {
            guard frames.count >= 2 else { throw Failure.tooFewFrames }
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.limit }
            var usedHeight = 0
            for frame in frames {
                try Task.checkCancellation()
                try autoreleasepool {
                    let image = try loadBounded(frame.url)
                    guard image.width == width, image.height == frameHeight else { throw Failure.dimensions }
                    let stripHeight = frameHeight - frame.overlap
                    guard let strip = image.cropping(to: CGRect(x: 0, y: frame.overlap, width: width, height: stripHeight)) else { throw Failure.unreadable }
                    context.draw(strip, in: CGRect(x: 0, y: height - usedHeight - stripHeight, width: width, height: stripHeight))
                    usedHeight += stripHeight
                }
            }
            guard let result = context.makeImage() else { throw Failure.limit }
            return result
        }

        private func loadBounded(_ url: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { throw Failure.unreadable }
            guard h <= maximumHeight, w <= 16_384, w <= maximumPixels / h else { throw Failure.limit }
            return try ScreenshotEditing.load(url)
        }

        private static func sample(_ image: CGImage) throws -> [UInt8] {
            let w = sampleWidth, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h)
            let made = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard made else { throw Failure.unreadable }
            return bytes
        }

        private static func matchesFullOverlap(_ previous: CGImage, _ next: CGImage, overlap: Int) throws -> Bool {
            guard previous.width == next.width, previous.height == next.height else { return false }
            let width = next.width
            var difference: Int64 = 0
            var componentCount: Int64 = 0
            for y in stride(from: 0, to: overlap, by: 128) {
                try Task.checkCancellation()
                let rows = min(128, overlap - y)
                func pixels(_ image: CGImage, startY: Int) throws -> [UInt8] {
                    guard let strip = image.cropping(to: CGRect(x: 0, y: startY, width: width, height: rows)) else { throw Failure.unreadable }
                    var bytes = [UInt8](repeating: 0, count: width * rows * 4)
                    let made = bytes.withUnsafeMutableBytes { buffer -> Bool in
                        guard let context = CGContext(data: buffer.baseAddress, width: width, height: rows, bitsPerComponent: 8,
                                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows))
                        return true
                    }
                    guard made else { throw Failure.limit }
                    return bytes
                }
                let a = try pixels(previous, startY: previous.height - overlap + y)
                let b = try pixels(next, startY: y)
                for index in a.indices {
                    let delta = abs(Int(a[index]) - Int(b[index]))
                    if delta > 12 { return false }
                    difference += Int64(delta)
                }
                componentCount += Int64(a.count)
            }
            return componentCount > 0 && Double(difference) / Double(componentCount) <= 2
        }

        private static func overlap(_ previous: [UInt8], _ next: [UInt8], height: Int) throws -> Int {
            let w = sampleWidth
            func error(shift: Int, rows: Int) -> Double {
                let count = height - shift
                var sum = 0
                for row in 0..<min(rows, count) {
                    let y = row * (count - 1) / max(1, min(rows, count) - 1)
                    for x in stride(from: 1, to: w - 1, by: 2) {
                        sum += abs(Int(previous[(y + shift) * w + x]) - Int(next[y * w + x]))
                    }
                }
                return Double(sum) / Double(min(rows, count) * ((w - 2) / 2))
            }
            if error(shift: 0, rows: 128) < 0.7 { throw Failure.duplicate }
            let minimumOverlap = max(8, (height + 3) / 4)
            guard height > minimumOverlap else { throw Failure.uncertainOverlap }
            var candidates: [(shift: Int, error: Double)] = []
            for shift in 1...(height - minimumOverlap) {
                if shift % 128 == 0 { try Task.checkCancellation() }
                let score = error(shift: shift, rows: 40)
                if score < 8 { candidates.append((shift, score)) }
            }
            guard !candidates.isEmpty else { throw Failure.uncertainOverlap }
            candidates.sort { $0.error < $1.error }
            var refined: [(shift: Int, error: Double)] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let count = height - candidate.shift
                let allowance = count * w * 3
                var total = 0
                for y in 0..<count {
                    for x in 0..<w {
                        total += abs(Int(previous[(y + candidate.shift) * w + x]) - Int(next[y * w + x]))
                    }
                    if total > allowance { break }
                }
                let score = Double(total) / Double(count * w)
                if score < 3 { refined.append((candidate.shift, score)) }
            }
            refined.sort { $0.error < $1.error }
            guard let best = refined.first else { throw Failure.uncertainOverlap }
            if refined.dropFirst().contains(where: { abs($0.shift - best.shift) > 2 && $0.error <= best.error + max(0.15, best.error * 0.25) }) {
                throw Failure.uncertainOverlap
            }
            let count = height - best.shift
            var sum = 0.0, squared = 0.0, samples = 0.0
            for row in 0..<min(128, count) {
                let y = row * (count - 1) / max(1, min(128, count) - 1)
                for x in stride(from: 1, to: w - 1, by: 2) {
                    let value = Double(next[y * w + x])
                    sum += value; squared += value * value; samples += 1
                }
            }
            guard squared / samples - pow(sum / samples, 2) > 64 else { throw Failure.uncertainOverlap }
            return count
        }
    }
}
#endif
