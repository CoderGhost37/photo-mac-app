import Foundation

#if canImport(CoreML) && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import CoreML
import ImageIO

/// Loads the Core ML CLIP program produced by `Scripts/fetch-clip.sh`.
/// Predictions use the CPU and GPU, so the same model runs on Intel and Apple silicon.
public final class CoreMLClipEmbedder: @unchecked Sendable {
    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let lock = NSLock()

    public init(directory: URL) throws {
        let manifestURL = directory.appendingPathComponent(ClipModel.checksumName)
        guard ClipInstall.isComplete(directory: directory),
              let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw ClipModelError.incomplete
        }
        let expected = ModelChecksums.parse(manifest)
        let actual = try ModelChecksums.hashTree(directory: directory)
        let problems = ModelChecksums.failures(expected: expected, actual: actual)
        guard problems.isEmpty, !expected.isEmpty else {
            throw ClipModelError.checksumMismatch(problems)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        imageModel = try MLModel(contentsOf: directory.appendingPathComponent(ClipModel.imageModelName), configuration: configuration)
        textModel = try MLModel(contentsOf: directory.appendingPathComponent(ClipModel.textModelName), configuration: configuration)
        tokenizer = try CLIPTokenizer(vocabularyAt: directory.appendingPathComponent(ClipModel.vocabularyName))
    }

    public func embed(file url: URL) throws -> [Float] {
        guard let image = Self.thumbnail(at: url) else {
            throw ClipModelError.unreadableModel("The picture could not be read.")
        }
        return try embed(cgImage: image)
    }

    public func embed(cgImage: CGImage) throws -> [Float] {
        let prepared = Self.render(cgImage, side: ClipModel.imageSide) ?? cgImage
        guard let constraint = imageModel.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw ClipModelError.unreadableModel("The image model has no image input named image.")
        }
        let feature = try MLFeatureValue(cgImage: prepared, orientation: .up, constraint: constraint, options: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": feature])
        lock.lock()
        defer { lock.unlock() }
        let result = try imageModel.prediction(from: provider)
        guard let values = result.featureValue(for: "embedding")?.multiArrayValue else {
            throw ClipModelError.unreadableModel("The image model did not return embedding.")
        }
        let flat = Self.floats(values)
        guard flat.count == ClipModel.dimension else {
            throw ClipModelError.unreadableModel("The image embedding has \(flat.count) values.")
        }
        return EmbeddingMath.unitLength(flat)
    }

    public func embed(text: String) throws -> [Float] {
        let tokens = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokenizer.contextLength)], dataType: .int32)
        for (index, token) in tokens.enumerated() where index < array.count {
            array[index] = NSNumber(value: token)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["tokens": array])
        lock.lock()
        defer { lock.unlock() }
        let result = try textModel.prediction(from: provider)
        guard let values = result.featureValue(for: "sequence")?.multiArrayValue else {
            throw ClipModelError.unreadableModel("The text model did not return sequence.")
        }
        guard let pooled = EmbeddingMath.pooledText(
            sequence: Self.floats(values),
            tokens: tokens,
            endOfText: tokenizer.endOfText,
            dimension: ClipModel.dimension
        ) else {
            throw ClipModelError.unreadableModel("The text sequence could not be read.")
        }
        return pooled
    }

    private static func thumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func render(_ image: CGImage, side: Int) -> CGImage? {
        guard side > 0, let crop = CenterSquare.crop(width: image.width, height: image.height),
              let cropped = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) else {
            return nil
        }
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }
}
#endif
