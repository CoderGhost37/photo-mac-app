import XCTest
@testable import PhotoIndex

final class ConvertLogicTests: XCTestCase {
    func testFormatMappingForStillsAndVideo() {
        XCTAssertEqual(
            ConvertRouting.formats(for: "HEIC"),
            [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif]
        )
        XCTAssertEqual(ConvertRouting.formats(for: "mov"), [.mp4, .hevc, .gif, .m4a])
        XCTAssertEqual(ConvertRouting.formats(for: "mp4"), ConvertRouting.formats(for: "mov"))
        XCTAssertEqual(ConvertRouting.kind(fileExtension: "pdf"), .unsupported)
        XCTAssertTrue(ConvertRouting.formats(for: "pdf").isEmpty)
        XCTAssertNil(ConvertRouting.rejection(fileName: "cabin.heic", fileExtension: "heic", format: .jpeg))
        XCTAssertFalse(ConvertRouting.allows(.jpeg, fileExtension: "mov"))
        let video = ConvertRouting.rejection(fileName: "clip.mov", fileExtension: "mov", format: .jpeg)
        XCTAssertEqual(video, "clip.mov is a video. JPEG is a still-image format.")
        let still = ConvertRouting.rejection(fileName: "notes.png", fileExtension: "png", format: .m4a)
        XCTAssertEqual(still, "notes.png is a still image. M4A is an audio extract from video.")
        XCTAssertTrue(ConvertRouting.allows(.gif, fileExtension: "jpg"))
        XCTAssertTrue(ConvertRouting.allows(.gif, fileExtension: "mov"))
    }

    func testWebPAndAVIFEncodeGates() {
        let catalinaWebP = availability(.webp, major: 10, minor: 15, destinations: nil)
        XCTAssertFalse(catalinaWebP.available)
        XCTAssertTrue(catalinaWebP.unavailableReason?.contains("cannot write") == true)

        let sonomaWebP = availability(.webp, major: 14, minor: 0, destinations: nil)
        XCTAssertFalse(sonomaWebP.available)

        let futureWebP = availability(.webp, major: 14, minor: 0, destinations: ["org.webmproject.webp", "public.jpeg"])
        XCTAssertTrue(futureWebP.available)
        XCTAssertNil(futureWebP.unavailableReason)

        let sequoiaAVIF = availability(.avif, major: 15, minor: 2, destinations: nil)
        XCTAssertFalse(sequoiaAVIF.available)
        XCTAssertTrue(sequoiaAVIF.unavailableReason?.contains("macOS 26") == true)

        let tahoeAVIF = availability(.avif, major: 26, minor: 0, destinations: nil)
        XCTAssertTrue(tahoeAVIF.available)

        let tahoeMissing = availability(.avif, major: 26, minor: 0, destinations: ["public.jpeg"])
        XCTAssertFalse(tahoeMissing.available)
        XCTAssertTrue(tahoeMissing.unavailableReason?.contains("does not list AVIF") == true)

        let listedEarly = availability(.avif, major: 14, minor: 0, destinations: ["public.avif"])
        XCTAssertTrue(listedEarly.available)

        XCTAssertTrue(availability(.heic, major: 10, minor: 13, destinations: nil).available)
        XCTAssertFalse(availability(.heic, major: 10, minor: 12, destinations: nil).available)
        XCTAssertTrue(availability(.jpeg, major: 14, minor: 0, destinations: ["public.jpeg"]).available)
        XCTAssertFalse(availability(.jpeg, major: 14, minor: 0, destinations: []).available)
    }

    func testHEVCPresetGate() {
        XCTAssertTrue(MovieEncodeTable.hevcAvailability(presetNames: nil).available)
        XCTAssertTrue(MovieEncodeTable.hevcAvailability(presetNames: [MovieEncodeTable.hevcPreset]).available)
        let missing = MovieEncodeTable.hevcAvailability(presetNames: ["AVAssetExportPresetHighestQuality"])
        XCTAssertFalse(missing.available)
        XCTAssertTrue(missing.unavailableReason?.contains("HEVC") == true)
    }

    func testOutputNamesDoNotOverwrite() throws {
        let root = "/library/photos"
        var reserved = Set<String>()
        let exists: (String) -> Bool = { path in
            path == "\(root)/cabin.jpg" || path == "\(root)/clip 2.mov"
        }
        let jpeg = try OutputNamer.allocate(
            displayName: "cabin.HEIC",
            sourcePath: "\(root)/cabin.HEIC",
            fileExtension: "jpg",
            directory: root,
            reserved: &reserved,
            exists: exists
        ).get()
        XCTAssertEqual(jpeg, "\(root)/cabin 2.jpg")

        let besideSelf = try OutputNamer.allocate(
            displayName: "cabin.jpg",
            sourcePath: "\(root)/cabin.jpg",
            fileExtension: "jpg",
            directory: root,
            reserved: &reserved,
            exists: exists
        ).get()
        XCTAssertEqual(besideSelf, "\(root)/cabin 3.jpg")

        let video = try OutputNamer.allocate(
            displayName: "clip.mov",
            sourcePath: "\(root)/clip.mov",
            fileExtension: "mov",
            directory: root,
            reserved: &reserved,
            exists: exists
        ).get()
        XCTAssertEqual(video, "\(root)/clip 3.mov")
        XCTAssertNotEqual(video, "\(root)/clip.mov")
    }

    func testBatchNamesAndCaseDoNotCollide() throws {
        var reserved = Set<String>()
        let first = try OutputNamer.allocate(
            displayName: "Shot.HEIC",
            sourcePath: "/a/Shot.HEIC",
            fileExtension: "jpg",
            directory: "/out",
            reserved: &reserved,
            exists: { _ in false }
        ).get()
        let second = try OutputNamer.allocate(
            displayName: "shot.png",
            sourcePath: "/b/shot.png",
            fileExtension: "jpg",
            directory: "/out",
            reserved: &reserved,
            exists: { _ in false }
        ).get()
        XCTAssertEqual(first, "/out/Shot.jpg")
        XCTAssertEqual(second, "/out/shot 2.jpg")

        var sensitive = Set<String>()
        let otherCase = try OutputNamer.allocate(
            displayName: "shot.png",
            sourcePath: "/b/shot.png",
            fileExtension: "jpg",
            directory: "/out",
            reserved: &sensitive,
            exists: { _ in false },
            caseInsensitive: false,
            forbiddenPaths: ["/out/Shot.jpg"]
        ).get()
        XCTAssertEqual(otherCase, "/out/shot.jpg")
    }

    func testPlannerSkipsOriginalsMismatchesAndMissingEncode() {
        let inputs = [
            ConvertPlanInput(displayName: "cabin.heic", sourcePath: "/photos/cabin.heic", fileExtension: "heic"),
            ConvertPlanInput(displayName: "cabin.jpg", sourcePath: "/photos/cabin.jpg", fileExtension: "jpg"),
            ConvertPlanInput(displayName: "clip.mov", sourcePath: "/photos/clip.mov", fileExtension: "mov"),
            ConvertPlanInput(displayName: "Library item", sourcePath: nil, fileExtension: "jpg")
        ]
        let jpeg = EncodeAvailability(format: .jpeg, available: true, unavailableReason: nil)
        let planned = ConvertPlanner.plan(
            inputs: inputs,
            format: .jpeg,
            place: .besideSource,
            encode: jpeg,
            exists: { _ in false }
        )
        XCTAssertEqual(planned.map(\.outputPath), [
            "/photos/cabin.jpg",
            "/photos/cabin 2.jpg",
            nil,
            nil
        ])
        XCTAssertNil(planned[0].skipReason)
        XCTAssertNotEqual(planned[1].outputPath, planned[1].sourcePath)
        XCTAssertTrue(planned[2].skipReason?.contains("video") == true)
        XCTAssertTrue(planned[3].skipReason?.contains("folder") == true)

        let folder = ConvertPlanner.plan(
            inputs: [inputs[3]],
            format: .jpeg,
            place: .folder("/exports"),
            encode: jpeg,
            exists: { _ in false }
        )
        XCTAssertEqual(folder.first?.outputPath, "/exports/Library item.jpg")

        let webp = EncodeAvailability(
            format: .webp,
            available: false,
            unavailableReason: "ImageIO on this Mac can open WebP files but cannot write them."
        )
        let blocked = ConvertPlanner.plan(
            inputs: [inputs[0]],
            format: .webp,
            place: .besideSource,
            encode: webp,
            exists: { _ in false }
        )
        XCTAssertNil(blocked.first?.outputPath)
        XCTAssertTrue(blocked.first?.skipReason?.contains("WebP") == true)
    }

    func testAtomicWriteDoesNotReplaceExistingOrOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let destination = root.appendingPathComponent("copy.txt")
        try Data("keep".utf8).write(to: original)

        try OutputNamer.writeAtomically(to: destination) { partial in
            try Data("new".utf8).write(to: partial)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")

        XCTAssertThrowsError(try OutputNamer.writeAtomically(to: original) { partial in
            try Data("changed".utf8).write(to: partial)
        }) { error in
            XCTAssertEqual(error as? OutputNameError, .destinationOccupied("original.txt"))
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")

        let missing = root.appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try OutputNamer.writeAtomically(to: missing) { _ in
            throw OutputNameError.writeFailed("missing.txt")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.contains("stillroom-part") })
    }

    func testPageLayoutFitLetterAndA4() throws {
        let landscape = PDFLayout.layout(paper: .a4, pixelWidth: 4000, pixelHeight: 3000)
        let page = try XCTUnwrap(landscape)
        XCTAssertGreaterThan(page.pageWidth, page.pageHeight)
        XCTAssertEqual(page.pageWidth, PDFLayout.a4Long, accuracy: 0.001)
        XCTAssertEqual(page.pageHeight, PDFLayout.a4Short, accuracy: 0.001)
        assertAspect(page, pixelsWide: 4000, pixelsHigh: 3000)
        assertCentered(page)
        XCTAssertGreaterThanOrEqual(page.imageX + 0.001, PDFLayout.margin)

        let portrait = PDFLayout.layout(paper: .letter, pixelWidth: 1200, pixelHeight: 1800)
        XCTAssertEqual(portrait?.pageWidth ?? 0, PDFLayout.letterShort, accuracy: 0.001)
        XCTAssertEqual(portrait?.pageHeight ?? 0, PDFLayout.letterLong, accuracy: 0.001)
        assertAspect(portrait, pixelsWide: 1200, pixelsHigh: 1800)
        assertCentered(portrait)

        let square = PDFLayout.layout(paper: .a4, pixelWidth: 1000, pixelHeight: 1000)
        XCTAssertEqual(square?.imageWidth ?? 0, square?.imageHeight ?? 0, accuracy: 0.001)
        XCTAssertEqual(square?.imageX ?? 0, PDFLayout.margin, accuracy: 0.001)

        let fit = PDFLayout.layout(paper: .fit, pixelWidth: 1440, pixelHeight: 720)
        XCTAssertEqual(fit?.pageWidth ?? 0, 720, accuracy: 0.001)
        XCTAssertEqual(fit?.pageHeight ?? 0, 360, accuracy: 0.001)
        XCTAssertEqual(fit?.imageX ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(fit?.imageY ?? 1, 0, accuracy: 0.001)
        XCTAssertNil(PDFLayout.layout(paper: .a4, pixelWidth: 0, pixelHeight: 10))

        let embed = PDFLayout.embedPixelSize(
            layout: try XCTUnwrap(landscape),
            sourceWidth: 4000,
            sourceHeight: 3000
        )
        XCTAssertLessThan(embed?.width ?? 0, 4000)
        XCTAssertEqual(
            Double(embed?.width ?? 0) / Double(embed?.height ?? 1),
            4000.0 / 3000.0,
            accuracy: 0.02
        )
        let small = PDFLayout.layout(paper: .fit, pixelWidth: 20, pixelHeight: 10)
        let kept = PDFLayout.embedPixelSize(layout: try XCTUnwrap(small), sourceWidth: 20, sourceHeight: 10)
        XCTAssertEqual(kept, PixelSize(width: 20, height: 10))
    }

    func testPageOrderAndCropMath() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let items = [
            PDFPageRef(id: "b", name: "b", date: newer),
            PDFPageRef(id: "A", name: "a", date: nil),
            PDFPageRef(id: "a2", name: "a", date: older)
        ]
        XCTAssertEqual(PDFPageOrdering.ordered(items, by: .listed).map(\.id), ["b", "A", "a2"])
        XCTAssertEqual(PDFPageOrdering.ordered(items, by: .name).map(\.id), ["A", "a2", "b"])
        XCTAssertEqual(PDFPageOrdering.ordered(items, by: .date).map(\.id), ["a2", "b", "A"])

        let full = ImageEditMath.outputSize(pixelWidth: 200, pixelHeight: 100, rotation: .none, crop: .full)
        XCTAssertEqual(full, PixelSize(width: 200, height: 100))
        let turned = ImageEditMath.outputSize(pixelWidth: 200, pixelHeight: 100, rotation: .clockwise, crop: .full)
        XCTAssertEqual(turned, PixelSize(width: 100, height: 200))
        let cropped = CropInsets(left: 0.25, right: 0.25, top: 0, bottom: 0).rect()
        let size = ImageEditMath.outputSize(pixelWidth: 200, pixelHeight: 100, rotation: .half, crop: cropped)
        XCTAssertEqual(size, PixelSize(width: 100, height: 100))
        let tight = CropInsets(left: 0.9, right: 0.9, top: 0, bottom: 0).rect()
        XCTAssertGreaterThanOrEqual(tight.width, 0.05)
        XCTAssertLessThanOrEqual(tight.x + tight.width, 1.001)
        XCTAssertNil(ImageEditMath.outputSize(pixelWidth: 0, pixelHeight: 10, rotation: .none, crop: .full))
    }

    func testGIFFramePlanStaysInsideTheClip() {
        XCTAssertEqual(GIFSampling.plan(duration: 0), [0])
        let second = GIFSampling.plan(duration: 1)
        XCTAssertEqual(second.count, 8)
        XCTAssertEqual(second.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertLessThan(second.last ?? 2, 1)
        let long = GIFSampling.plan(duration: 100)
        XCTAssertEqual(long.count, GIFSampling.maxFrames)
        XCTAssertLessThan(long.last ?? 99, GIFSampling.maxDuration)
    }

    func testWorkQueueRunsOneAtATime() {
        var queue = WorkQueue()
        XCTAssertTrue(queue.enqueue(id: "a", title: "A"))
        XCTAssertTrue(queue.enqueue(id: "b", title: "B"))
        XCTAssertFalse(queue.enqueue(id: "a", title: "Again"))
        XCTAssertEqual(queue.nextID(), "a")
        XCTAssertTrue(queue.markRunning("a"))
        XCTAssertNil(queue.nextID())
        XCTAssertFalse(queue.markRunning("b"))
        XCTAssertFalse(queue.setProgress("b", 0.4))
        XCTAssertTrue(queue.setProgress("a", 2))
        XCTAssertEqual(queue.items[0].progress, 1, accuracy: 0.001)
        XCTAssertTrue(queue.setProgress("a", -1))
        XCTAssertEqual(queue.items[0].progress, 0, accuracy: 0.001)
        XCTAssertTrue(queue.succeed("a", outputPath: "/out/A.jpg"))
        XCTAssertEqual(queue.nextID(), "b")
        XCTAssertEqual(queue.cancelQueued(), ["b"])
        XCTAssertNil(queue.nextID())
        XCTAssertFalse(queue.fail("a", message: "no"))
        XCTAssertEqual(queue.finishedCount, 2)
        XCTAssertEqual(queue.overallProgress, 1, accuracy: 0.001)

        var skips = WorkQueue()
        XCTAssertTrue(skips.enqueue(id: "s", title: "Skip"))
        XCTAssertTrue(skips.fail("s", message: "not a photo"))
        XCTAssertEqual(skips.items[0].state, .failed)
        XCTAssertEqual(skips.overallProgress, 1, accuracy: 0.001)
    }

    private func availability(
        _ format: ConvertFormat,
        major: Int,
        minor: Int,
        destinations: Set<String>?
    ) -> EncodeAvailability {
        ImageEncodeTable.availability(major: major, minor: minor, destinationTypes: destinations)
            .first { $0.format == format }!
    }

    private func assertAspect(_ layout: PDFPageLayout?, pixelsWide: Double, pixelsHigh: Double) {
        let width = layout?.imageWidth ?? 0
        let height = layout?.imageHeight ?? 1
        XCTAssertEqual(width / height, pixelsWide / pixelsHigh, accuracy: 0.0001)
    }

    private func assertCentered(_ layout: PDFPageLayout?) {
        guard let layout else {
            XCTFail("missing layout")
            return
        }
        XCTAssertEqual(layout.imageX, (layout.pageWidth - layout.imageWidth) / 2, accuracy: 0.001)
        XCTAssertEqual(layout.imageY, (layout.pageHeight - layout.imageHeight) / 2, accuracy: 0.001)
    }
}
