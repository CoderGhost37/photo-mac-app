import Foundation

#if canImport(PDFKit) && canImport(ImageIO) && canImport(Vision) && canImport(CoreImage)
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import PDFKit
import Vision

public struct PDFImageSpec: Sendable {
    public var url: URL
    public var name: String
    public var rotation: QuarterTurns
    public var crop: NormalizedRect

    public init(url: URL, name: String, rotation: QuarterTurns, crop: NormalizedRect) {
        self.url = url
        self.name = name
        self.rotation = rotation
        self.crop = crop
    }
}

public struct PDFBuildResult: Equatable, Sendable {
    public var outputPath: String
    public var pageCount: Int
    public var warnings: [String]

    public init(outputPath: String, pageCount: Int, warnings: [String]) {
        self.outputPath = outputPath
        self.pageCount = pageCount
        self.warnings = warnings
    }
}

public enum PDFComposer {
    /// One image per page. Searchable text is drawn in invisible mode so it can be selected and is not a watermark.
    public static func makeDocument(
        pages: [PDFImageSpec],
        output: URL,
        paper: PDFPaper,
        recognizeText: Bool,
        cleanUp: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> PDFBuildResult {
        guard !pages.isEmpty else { throw PDFFailure.noPages }
        var warnings: [String] = []
        var prepared: [(CGImage, String)] = []
        prepared.reserveCapacity(pages.count)
        for (index, page) in pages.enumerated() {
            progress(index, pages.count)
            do {
                let image = try prepare(page, cleanUp: cleanUp)
                prepared.append((image, page.name))
            } catch {
                throw PDFFailure.unreadable(page.name)
            }
        }
        guard !prepared.isEmpty else { throw PDFFailure.noPages }
        try OutputNamer.writeAtomically(to: output) { partial in
            warnings.append(contentsOf: try write(
                prepared,
                to: partial,
                paper: paper,
                recognizeText: recognizeText
            ))
        }
        progress(pages.count, pages.count)
        return PDFBuildResult(outputPath: output.path, pageCount: prepared.count, warnings: warnings)
    }

    public static func merge(inputs: [URL], output: URL) throws -> PDFBuildResult {
        guard !inputs.isEmpty else { throw PDFFailure.noPages }
        let document = PDFDocument()
        var index = 0
        for url in inputs {
            guard let source = PDFDocument(url: url), source.pageCount > 0 else {
                throw PDFFailure.unreadable(url.lastPathComponent)
            }
            for pageIndex in 0..<source.pageCount {
                guard let page = source.page(at: pageIndex) else { continue }
                document.insert(page, at: index)
                index += 1
            }
        }
        guard index > 0 else { throw PDFFailure.noPages }
        try OutputNamer.writeAtomically(to: output) { partial in
            guard document.write(to: partial) else {
                throw PDFFailure.writeFailed(output.lastPathComponent)
            }
        }
        return PDFBuildResult(outputPath: output.path, pageCount: index, warnings: [])
    }

    /// Writes one PNG per page. Used for a Continuity Camera scan that arrives as a PDF.
    public static func renderPages(of pdfURL: URL, into directory: URL) throws -> [URL] {
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw PDFFailure.unreadable(pdfURL.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reserved = Set<String>()
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        var urls: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let path = try OutputNamer.allocate(
                displayName: "\(stem) page \(index + 1).png",
                sourcePath: pdfURL.path,
                fileExtension: "png",
                directory: directory.path,
                reserved: &reserved,
                exists: { FileManager.default.fileExists(atPath: $0) },
                forbiddenPaths: [pdfURL.path]
            ).get()
            let url = URL(fileURLWithPath: path)
            let image = try render(page)
            try OutputNamer.writeAtomically(to: url) { partial in
                try writePNG(image, to: partial)
            }
            urls.append(url)
        }
        guard !urls.isEmpty else { throw PDFFailure.noPages }
        return urls
    }

    private static func prepare(_ page: PDFImageSpec, cleanUp: Bool) throws -> CGImage {
        let loaded = try StillImageReader.orientedImage(at: page.url)
        let rotated = rotate(loaded, turns: page.rotation)
        let cleaned = cleanUp ? cleanDocument(rotated) : rotated
        guard let rect = page.crop.pixelRect(imageWidth: cleaned.width, imageHeight: cleaned.height) else {
            return cleaned
        }
        if rect.x == 0, rect.y == 0, rect.width == cleaned.width, rect.height == cleaned.height {
            return cleaned
        }
        return crop(cleaned, rect) ?? cleaned
    }

    private static func write(
        _ pages: [(CGImage, String)],
        to url: URL,
        paper: PDFPaper,
        recognizeText: Bool
    ) throws -> [String] {
        guard let first = pages.first,
              let firstLayout = PDFLayout.layout(paper: paper, pixelWidth: first.0.width, pixelHeight: first.0.height)
        else {
            throw PDFFailure.noPages
        }
        var media = CGRect(x: 0, y: 0, width: firstLayout.pageWidth, height: firstLayout.pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw PDFFailure.writeFailed(url.lastPathComponent)
        }
        var warnings: [String] = []
        for (image, name) in pages {
            guard let layout = PDFLayout.layout(paper: paper, pixelWidth: image.width, pixelHeight: image.height) else {
                warnings.append("\(name) has no size, so it was skipped.")
                continue
            }
            var box = CGRect(x: 0, y: 0, width: layout.pageWidth, height: layout.pageHeight)
            var boxBytes = box
            let boxData = Data(bytes: &boxBytes, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            let embedded = scaled(image, layout: layout)
            let imageRect = CGRect(x: layout.imageX, y: layout.imageY, width: layout.imageWidth, height: layout.imageHeight)
            context.draw(embedded, in: imageRect)
            if recognizeText {
                do {
                    try drawSearchableText(in: embedded, imageRect: imageRect, context: context)
                } catch {
                    warnings.append("\(name) was saved without searchable text.")
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return warnings
    }

    private static func drawSearchableText(in image: CGImage, imageRect: CGRect, context: CGContext) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let box = observation.boundingBox
            let rect = CGRect(
                x: imageRect.minX + box.minX * imageRect.width,
                y: imageRect.minY + box.minY * imageRect.height,
                width: box.width * imageRect.width,
                height: box.height * imageRect.height
            )
            drawInvisible(cleaned, in: rect, context: context)
        }
    }

    /// Text rendering mode 3. The glyphs stay in the page and are not painted.
    private static func drawInvisible(_ text: String, in rect: CGRect, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent
        guard width > 0, height > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / width, y: rect.height / height)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func cleanDocument(_ image: CGImage) -> CGImage {
        let straightened = perspectiveCorrected(image) ?? image
        return contrasted(straightened) ?? straightened
    }

    private static func perspectiveCorrected(_ image: CGImage) -> CGImage? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.2
        request.minimumSize = 0.2
        request.quadratureTolerance = 30
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else {
            return nil
        }
        let source = CIImage(cgImage: image)
        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: pixel(observation.topLeft, extent: extent)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: pixel(observation.topRight, extent: extent)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: pixel(observation.bottomLeft, extent: extent)), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: pixel(observation.bottomRight, extent: extent)), forKey: "inputBottomRight")
        guard let output = filter.outputImage, output.extent.width > 1, output.extent.height > 1 else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(output, from: output.extent)
    }

    private static func contrasted(_ image: CGImage) -> CGImage? {
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        let source = CIImage(cgImage: image)
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(1.15, forKey: kCIInputContrastKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(output, from: output.extent)
    }

    private static func pixel(_ point: CGPoint, extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.minX + point.x * extent.width,
            y: extent.minY + point.y * extent.height
        )
    }

    /// Clockwise turns. Core Graphics angles are counterclockwise, so the sign is flipped.
    private static func rotate(_ image: CGImage, turns: QuarterTurns) -> CGImage {
        guard turns != .none else { return image }
        let swapped = turns == .clockwise || turns == .counterClockwise
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns.degrees) * .pi / 180)
        context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func crop(_ image: CGImage, _ rect: PixelRect) -> CGImage? {
        image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    private static func scaled(_ image: CGImage, layout: PDFPageLayout) -> CGImage {
        guard let target = PDFLayout.embedPixelSize(
            layout: layout,
            sourceWidth: image.width,
            sourceHeight: image.height
        ), target.width < image.width || target.height < image.height else {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage() ?? image
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFFailure.unreadable("page")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw PDFFailure.unreadable("page") }
        return image
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw PDFFailure.writeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PDFFailure.writeFailed(url.lastPathComponent)
        }
    }
}
#endif
