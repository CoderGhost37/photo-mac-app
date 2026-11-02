import Foundation

public struct StoredSubject: Equatable, Sendable {
    public var id: String
    public var assetID: String
    public var kind: SubjectKind
    public var box: NormalizedBox
    public var confidence: Double
    public var vector: [Float]

    public init(
        id: String,
        assetID: String,
        kind: SubjectKind,
        box: NormalizedBox,
        confidence: Double,
        vector: [Float]
    ) {
        self.id = id
        self.assetID = assetID
        self.kind = kind
        self.box = box
        self.confidence = confidence
        self.vector = vector
    }
}

public struct SceneLabel: Equatable, Sendable {
    public var label: String
    public var confidence: Double

    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

public enum SubjectSampleID {
    public static func make(assetID: String, kind: SubjectKind, index: Int) -> String {
        "\(assetID)|\(kind.rawValue)|\(index)"
    }
}

#if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import Vision

public struct VisionRead: Equatable, Sendable {
    public var subjects: [StoredSubject]
    public var labels: [SceneLabel]
    public var imageVector: [Float]?

    public init(subjects: [StoredSubject], labels: [SceneLabel], imageVector: [Float]?) {
        self.subjects = subjects
        self.labels = labels
        self.imageVector = imageVector
    }
}

public enum RasterImage {
    public static func cgImage(at url: URL, maxPixel: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Face prints, pet prints, scene labels, and one image print. All of it stays on device.
public enum VisionMemory {
    public static func read(cgImage: CGImage, assetID: String) throws -> VisionRead {
        let subjects = try peopleAndPets(in: cgImage, assetID: assetID)
        let labels = classify(cgImage)
        let imageVector = imagePrint(cgImage)
        return VisionRead(subjects: subjects, labels: labels, imageVector: imageVector)
    }

    public static func floats(from observation: VNFeaturePrintObservation) -> [Float]? {
        let data = observation.data
        switch observation.elementType {
        case .unknown:
            return nil
        case .float:
            let count = data.count / MemoryLayout<Float>.size
            guard count > 0, count == observation.elementCount else { return nil }
            return data.withUnsafeBytes { raw in
                var values: [Float] = []
                values.reserveCapacity(count)
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
                    values.append(Float(bitPattern: bits))
                }
                return values
            }
        case .double:
            let count = data.count / MemoryLayout<Double>.size
            guard count > 0, count == observation.elementCount else { return nil }
            return data.withUnsafeBytes { raw in
                var values: [Float] = []
                values.reserveCapacity(count)
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self).littleEndian
                    values.append(Float(Double(bitPattern: bits)))
                }
                return values
            }
        @unknown default:
            return nil
        }
    }

    private static func peopleAndPets(in image: CGImage, assetID: String) throws -> [StoredSubject] {
        var subjects: [StoredSubject] = []
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        try handler.perform([faces])
        let faceObservations = (faces.results ?? []).filter { face in
            face.boundingBox.width >= 0.02 && face.boundingBox.height >= 0.02
        }
        if !faceObservations.isEmpty {
            let prints = VNGenerateFaceFeaturePrintRequest()
            prints.inputFaceObservations = faceObservations
            try handler.perform([prints])
            let featurePrints = prints.results ?? []
            if featurePrints.count == faceObservations.count {
                for (index, pair) in zip(faceObservations, featurePrints).enumerated() {
                    guard let vector = floats(from: pair.1), !vector.isEmpty else { continue }
                    subjects.append(StoredSubject(
                        id: SubjectSampleID.make(assetID: assetID, kind: .person, index: index),
                        assetID: assetID,
                        kind: .person,
                        box: box(pair.0.boundingBox),
                        confidence: Double(pair.0.confidence),
                        vector: vector
                    ))
                }
            }
        }

        let animals = VNRecognizeAnimalsRequest()
        try handler.perform([animals])
        var petIndex: [SubjectKind: Int] = [:]
        for observation in animals.results ?? [] {
            guard let label = observation.labels.max(by: { $0.confidence < $1.confidence }) else { continue }
            let name = label.identifier.lowercased()
            let kind: SubjectKind
            if name.contains("cat") {
                kind = .cat
            } else if name.contains("dog") {
                kind = .dog
            } else {
                continue
            }
            guard let crop = crop(image, normalized: observation.boundingBox),
                  let vector = imagePrint(crop), !vector.isEmpty else { continue }
            let index = petIndex[kind] ?? 0
            petIndex[kind] = index + 1
            subjects.append(StoredSubject(
                id: SubjectSampleID.make(assetID: assetID, kind: kind, index: index),
                assetID: assetID,
                kind: kind,
                box: box(observation.boundingBox),
                confidence: Double(label.confidence),
                vector: vector
            ))
        }
        return subjects
    }

    private static func classify(_ image: CGImage) -> [SceneLabel] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNClassifyImageRequest()
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.1 }
            .prefix(12)
            .map { SceneLabel(label: $0.identifier, confidence: Double($0.confidence)) }
    }

    private static func imagePrint(_ image: CGImage) -> [Float]? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return nil }
        return floats(from: observation)
    }

    private static func box(_ rect: CGRect) -> NormalizedBox {
        NormalizedBox(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height).clamped()
    }

    private static func crop(_ image: CGImage, normalized: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(
            x: normalized.origin.x * width,
            y: (1 - normalized.origin.y - normalized.height) * height,
            width: normalized.width * width,
            height: normalized.height * height
        ).integral
        guard rect.width >= 20, rect.height >= 20 else { return nil }
        return image.cropping(to: rect)
    }
}
#endif
