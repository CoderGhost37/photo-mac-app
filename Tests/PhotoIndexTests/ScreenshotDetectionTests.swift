import XCTest
@testable import PhotoIndex

final class ScreenshotDetectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let path = "/screenshots/localized-name.png"

    private func image(created: TimeInterval = 1_001, modified: TimeInterval = 1_001,
                       bytes: Int64 = 128, native: Bool = true, readable: Bool = true) -> ScreenshotDetection.Observation {
        .init(creationDate: Date(timeIntervalSince1970: created),
              modificationDate: Date(timeIntervalSince1970: modified), byteCount: bytes,
              isNativeScreenshot: native, isReadableImage: readable)
    }

    func testPreexistingFileNeverOpensEvenWhenEdited() {
        var detector = ScreenshotDetection(startedAt: start, existingPaths: [path])
        XCTAssertEqual(detector.observe(path: path, observation: image()), .ignore)
        XCTAssertEqual(detector.observe(path: path, observation: image(modified: 1_005)), .ignore)
    }

    func testOldCreationOrModificationRejectsDelayedEventsAndCopiedCaptures() {
        for observation in [image(created: 999), image(modified: 999)] {
            var detector = ScreenshotDetection(startedAt: start)
            XCTAssertEqual(detector.observe(path: path, observation: observation), .ignore)
        }
    }

    func testArbitraryImagesAndEmptyOrUnreadableFilesNeverCapture() {
        for observation in [image(native: false), image(readable: false), image(bytes: 0)] {
            var detector = ScreenshotDetection(startedAt: start)
            for _ in 0..<20 {
                XCTAssertEqual(detector.observe(path: path, observation: observation), .retry)
            }
        }
    }

    func testCaptureNeedsTwoStableReadableObservationsAndDeduplicatesEvents() {
        var detector = ScreenshotDetection(startedAt: start)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .capture)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .ignore)
        XCTAssertEqual(detector.observe(path: path, observation: image(modified: 1_010)), .ignore)
    }

    func testFileStillWritingOrWaitingForMetadataCanCompleteLater() {
        var detector = ScreenshotDetection(startedAt: start)
        XCTAssertEqual(detector.observe(path: path, observation: nil), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image(native: false)), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image(bytes: 256)), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image(bytes: 256)), .capture)
    }

    func testUnreadableObservationResetsStability() {
        var detector = ScreenshotDetection(startedAt: start)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image(readable: false)), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: nil), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .capture)
    }

    func testIgnoringAnExportSuppressesAnAlreadyPendingCandidate() {
        var detector = ScreenshotDetection(startedAt: start)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        detector.ignore(path: path)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .ignore)
    }

    func testIndependentFilesCanCompleteInEitherOrder() {
        var detector = ScreenshotDetection(startedAt: start)
        let second = "/screenshots/second.png"
        XCTAssertEqual(detector.observe(path: path, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: second, observation: image()), .retry)
        XCTAssertEqual(detector.observe(path: second, observation: image()), .capture)
        XCTAssertEqual(detector.observe(path: path, observation: image()), .capture)
    }
}
