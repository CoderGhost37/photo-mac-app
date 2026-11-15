#if canImport(AppKit)
import AppKit
import ImageIO
import CoreText
import XCTest
@testable import PhotoIndex

final class ScreenshotStitchingTests: XCTestCase {
    private func source(width: Int = 96, height: Int = 400, repeated: Bool = false, seed: Int = 0) -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let row = repeated ? y % 16 : y
                let value = UInt8(truncatingIfNeeded: (row &* 73) ^ (x &* 131) ^ (row &* x &* 17) ^ seed)
                bytes += [value, value, value, 255]
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func frame(_ source: CGImage, y: Int, height: Int = 160, in folder: URL) throws -> URL {
        let image = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: y, width: source.width, height: height)))
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        try ScreenshotEditing.pngData(image).write(to: url)
        return url
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testSparseTextPageStitchesWithoutTreatingAdjacentRowsAsAmbiguous() throws {
        let width = 1600, height = 5200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let words = ["stillroom", "capture", "overlap", "frame", "window", "scrolling", "pixel", "region", "display", "manual", "preview", "local"]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(count))
        }
        var y: CGFloat = 40
        while y < CGFloat(height) - 20 {
            for _ in 0..<(1 + random(2)) {
                let text = (0..<(10 + random(8))).map { _ in words[random(words.count)] }.joined(separator: " ")
                let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)
                ]))
                context.textPosition = CGPoint(x: 60, y: CGFloat(height) - y - 30)
                CTLineDraw(line, context)
                y += 44
            }
            y += 44 * CGFloat(3 + random(6))
        }
        let original = try XCTUnwrap(context.makeImage()), directory = try folder()
        var session = ScreenshotStitching.Session()
        for offset in stride(from: 0, through: 3600, by: 600) {
            try session.append(frame(original, y: offset, height: 1200, in: directory))
        }
        XCTAssertEqual(session.frames.count, 7)
        XCTAssertEqual(session.height, 4800)
        let expected = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 0, width: width, height: 4800)))
        XCTAssertTrue(pixels(try session.render()) == pixels(expected))
    }

    func testKnownOverlapProducesActualOrderedPixels() throws {
        let directory = try folder(), original = source()
        var session = ScreenshotStitching.Session()
        try session.append(frame(original, y: 0, in: directory))
        try session.append(frame(original, y: 100, in: directory))
        try session.append(frame(original, y: 200, in: directory))
        XCTAssertEqual(session.frames.map(\.overlap), [0, 60, 60])
        XCTAssertEqual(session.height, 360)
        let result = try session.render()
        XCTAssertEqual(result.width, 96)
        XCTAssertEqual(result.height, 360)
        XCTAssertEqual(pixels(result), pixels(try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 360)))))
    }

    func testUnrelatedFramesDoNotChangeAcceptedFrames() throws {
        let directory = try folder()
        var session = ScreenshotStitching.Session()
        try session.append(frame(source(), y: 0, in: directory))
        XCTAssertThrowsError(try session.append(frame(source(seed: 91), y: 180, in: directory))) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .uncertainOverlap)
        }
        XCTAssertEqual(session.frames.count, 1)
        XCTAssertEqual(session.height, 160)
    }

    func testDuplicateAndPeriodicOverlapAreRejected() throws {
        let directory = try folder()
        var session = ScreenshotStitching.Session()
        let original = source(repeated: true)
        let first = try frame(original, y: 0, in: directory)
        try session.append(first)
        XCTAssertThrowsError(try session.append(first)) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .duplicate)
        }
        XCTAssertThrowsError(try session.append(frame(original, y: 70, in: directory))) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .uncertainOverlap)
        }
        XCTAssertEqual(session.frames.count, 1)
    }

    func testMatchingAlternateColumnsCannotHideUnrelatedColumns() throws {
        let directory = try folder(), original = source(width: 48)
        var session = ScreenshotStitching.Session()
        try session.append(frame(original, y: 0, in: directory))
        let next = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 100, width: 48, height: 160)))
        var bytes = pixels(next)
        for y in 0..<160 {
            for x in stride(from: 0, to: 48, by: 2) {
                for component in 0..<3 { bytes[(y * 48 + x) * 4 + component] ^= 255 }
            }
        }
        let changed = try XCTUnwrap(CGImage(width: 48, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 48 * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent("alternate-columns.png")
        try ScreenshotEditing.pngData(changed).write(to: url)
        XCTAssertThrowsError(try session.append(url)) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .uncertainOverlap)
        }
        XCTAssertEqual(session.frames.count, 1)
    }

    func testSparseMatchesCannotHideChangedPixels() throws {
        let directory = try folder(), original = source()
        var session = ScreenshotStitching.Session()
        try session.append(frame(original, y: 0, in: directory))
        let next = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 100, width: 96, height: 160)))
        var bytes = pixels(next)
        let changedPixel = (20 * 96 + 20) * 4
        bytes[changedPixel] = bytes[changedPixel] < 128 ? 255 : 0
        let changed = try XCTUnwrap(CGImage(width: 96, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 96 * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent("changed.png")
        try ScreenshotEditing.pngData(changed).write(to: url)
        XCTAssertThrowsError(try session.append(url)) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .uncertainOverlap)
        }
        XCTAssertEqual(session.frames.count, 1)
    }

    func testDifferentDimensionsAndHeightLimitAreRejected() throws {
        let directory = try folder(), original = source()
        var session = ScreenshotStitching.Session(maximumHeight: 200)
        try session.append(frame(original, y: 0, in: directory))
        XCTAssertThrowsError(try session.append(frame(source(width: 80), y: 100, in: directory))) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .dimensions)
        }
        XCTAssertThrowsError(try session.append(frame(original, y: 100, in: directory))) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .limit)
        }
        XCTAssertEqual(session.frames.count, 1)
    }

    func testPixelLimitAndMinimumFrameCount() throws {
        let directory = try folder()
        var session = ScreenshotStitching.Session(maximumPixels: 100)
        XCTAssertThrowsError(try session.append(frame(source(), y: 0, in: directory))) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .limit)
        }
        XCTAssertThrowsError(try session.render()) {
            XCTAssertEqual($0 as? ScreenshotStitching.Failure, .tooFewFrames)
        }
        XCTAssertEqual(ScreenshotStitching.Session(maximumHeight: 60_000).maximumHeight, 30_000)
    }
}
#endif
