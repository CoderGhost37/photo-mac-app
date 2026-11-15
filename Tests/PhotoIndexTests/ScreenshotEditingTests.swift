#if canImport(AppKit)
import AppKit
import ImageIO
import XCTest
@testable import PhotoIndex

final class ScreenshotEditingTests: XCTestCase {
    private func source() -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<12 {
            for _ in 0..<20 { bytes += y < 6 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        }
        return CGImage(width: 20, height: 12, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 80,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let bytes = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    func testDisplayMappingUsesImagePixelsAndLetterboxOrigin() {
        let frame = CGRect(x: 50, y: 100, width: 500, height: 300)
        let point = ScreenshotEditing.pixelPoint(CGPoint(x: 300, y: 250), displayedIn: frame, imageSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(point, CGPoint(x: 1000, y: 600))
        XCTAssertEqual(ScreenshotEditing.pixelPoint(.zero, displayedIn: frame, imageSize: CGSize(width: 2000, height: 1200)), .zero)
    }

    func testCropAndOpaqueRedactionUseTopLeftCoordinates() throws {
        let result = try ScreenshotEditing.render(source(), marks: [.redaction(CGRect(x: 2, y: 1, width: 4, height: 3))], crop: CGRect(x: 1, y: 0, width: 10, height: 8))
        XCTAssertEqual(result.width, 10)
        XCTAssertEqual(result.height, 8)
        // Normalize the cropped provider before reading; cropping may retain a larger row stride.
        let png = try ScreenshotEditing.pngData(result)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
        XCTAssertEqual(rgba(decoded, x: 2, y: 2), [0, 0, 0, 255])
        XCTAssertEqual(rgba(decoded, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(rgba(decoded, x: 0, y: 7), [0, 0, 255, 255])
    }

    func testArrowAndTextRenderAtOriginalPixelCoordinates() throws {
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let result = try ScreenshotEditing.render(context.makeImage()!, marks: [
            .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 10), width: 3),
            .text("Label", at: CGPoint(x: 10, y: 30), size: 12)
        ])
        let arrow = rgba(result, x: 30, y: 10)
        XCTAssertGreaterThan(arrow[0], arrow[1])
        XCTAssertEqual(rgba(result, x: 30, y: 70), [255, 255, 255, 255])
        var coloredTextPixels = 0
        for y in 30..<48 {
            for x in 10..<60 {
                let pixel = rgba(result, x: x, y: y)
                if pixel[0] > pixel[1] { coloredTextPixels += 1 }
            }
        }
        XCTAssertGreaterThan(coloredTextPixels, 10)
    }

    func testExplicitArrowColorDoesNotChangeOpaqueRedaction() throws {
        let result = try ScreenshotEditing.render(source(), marks: [
            .arrow(from: CGPoint(x: 1, y: 8), to: CGPoint(x: 18, y: 8), width: 2, color: .green),
            .redaction(CGRect(x: 10, y: 7, width: 3, height: 3))
        ])
        let colored = rgba(result, x: 5, y: 8)
        XCTAssertGreaterThan(colored[1], colored[0])
        XCTAssertEqual(rgba(result, x: 11, y: 8), [0, 0, 0, 255])
    }

    func testSelectionGeometryMovesClampsAndResizesWithoutLosingIdentity() {
        let annotation = ScreenshotAnnotation(mark: .redaction(CGRect(x: 10, y: 20, width: 30, height: 40)))
        XCTAssertTrue(annotation.mark.hitTest(CGPoint(x: 9, y: 30), tolerance: 2))
        XCTAssertFalse(annotation.mark.hitTest(CGPoint(x: 0, y: 0), tolerance: 2))
        var moved = annotation
        moved.mark = annotation.mark.moved(by: CGSize(width: 200, height: -200), inside: CGSize(width: 100, height: 100))
        XCTAssertEqual(moved.id, annotation.id)
        XCTAssertEqual(moved.mark.bounds, CGRect(x: 70, y: 0, width: 30, height: 40))
        XCTAssertEqual(annotation.mark.resized(handle: .bottomRight, to: CGPoint(x: 80, y: 90)).bounds,
                       CGRect(x: 10, y: 20, width: 70, height: 70))
    }

    func testArrowHitTestingUsesLineInsteadOfBoundingBoxAndEndpointResize() {
        let arrow = ScreenshotMark.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 90), width: 3, color: .blue)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 53), tolerance: 4))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 15, y: 85), tolerance: 4))
        let resized = arrow.resized(handle: .end, to: CGPoint(x: 80, y: 20))
        XCTAssertEqual(resized, .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 20), width: 3, color: .blue))
    }

    func testTextResizeKeepsOppositeCornerAndMakesTextLarger() {
        let mark = ScreenshotMark.text("Label", at: CGPoint(x: 20, y: 30), size: 12, color: .green)
        let resized = mark.resized(handle: .bottomRight, to: CGPoint(x: 20 + mark.bounds.width * 2, y: 60))
        XCTAssertEqual(resized.bounds.origin, mark.bounds.origin)
        XCTAssertGreaterThan(resized.bounds.width, mark.bounds.width)
        guard case let .text(text, _, size, color) = resized else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "Label")
        XCTAssertEqual(size, 24, accuracy: 0.01)
        XCTAssertEqual(color, .green)
    }

    func testUndoRedoRestoresFullStateAndNewEditClearsRedo() {
        let empty = ScreenshotEditState()
        var first = empty
        first.annotations = [ScreenshotAnnotation(mark: .text("Before", at: .zero, size: 12))]
        var second = first
        second.annotations[0].mark = .text("After", at: CGPoint(x: 10, y: 20), size: 24, color: .blue)
        second.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        second.background.style = .gradient
        var history = ScreenshotEditHistory()
        history.record(empty, replacing: first)
        history.record(first, replacing: second)
        XCTAssertEqual(history.undo(second), first)
        XCTAssertEqual(history.redo(first), second)
        XCTAssertEqual(history.undo(second), first)
        var replacement = first
        replacement.background.style = .solid
        history.record(first, replacing: replacement)
        XCTAssertNil(history.redo(replacement))
        XCTAssertEqual(history.undo(replacement), first)
        XCTAssertEqual(history.undo(first), empty)
    }

    func testCropHappensBeforeBackgroundAndKeepsRedactionOpaque() throws {
        var background = ScreenshotBackground()
        background.style = .solid
        background.color = .white
        background.padding = 4
        background.cornerRadius = 0
        background.shadow = false
        let result = try ScreenshotEditing.render(source(), marks: [.redaction(CGRect(x: 2, y: 1, width: 4, height: 3))],
                                                   crop: CGRect(x: 1, y: 0, width: 10, height: 8), background: background)
        XCTAssertEqual(result.width, 18)
        XCTAssertEqual(result.height, 16)
        XCTAssertEqual(rgba(result, x: 0, y: 0), [255, 255, 255, 255])
        XCTAssertEqual(rgba(result, x: 4, y: 4), [255, 0, 0, 255])
        XCTAssertEqual(rgba(result, x: 6, y: 6), [0, 0, 0, 255])
        XCTAssertEqual(rgba(result, x: 4, y: 11), [0, 0, 255, 255])
    }

    func testGradientRoundedCornersAndNoBackgroundDimensions() throws {
        var background = ScreenshotBackground()
        background.padding = 0
        background.cornerRadius = 4
        background.shadow = false
        XCTAssertEqual(try ScreenshotEditing.render(source(), marks: [], background: background).width, 20)
        background.style = .gradient
        background.color = .white
        background.secondColor = .black
        let result = try ScreenshotEditing.render(source(), marks: [], background: background)
        XCTAssertNotEqual(rgba(result, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertNotEqual(rgba(result, x: 0, y: 0), rgba(result, x: 19, y: 11))
        XCTAssertEqual(rgba(result, x: 10, y: 2), [255, 0, 0, 255])
    }

    func testCopyNamingPreservesOriginalAndExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Screenshot.png")
        let originalData = try ScreenshotEditing.pngData(source())
        try originalData.write(to: original)
        let first = try ScreenshotEditing.saveCopy(source(), suggestedURL: original, originalURL: original)
        let second = try ScreenshotEditing.saveCopy(source(), suggestedURL: original, originalURL: original)
        XCTAssertEqual(first.lastPathComponent, "Screenshot 2.png")
        XCTAssertEqual(second.lastPathComponent, "Screenshot 3.png")
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }
}
#endif
