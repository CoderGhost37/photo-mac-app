import Foundation

#if canImport(Vision)
import CoreGraphics
import Vision

/// On-device text recognition. Accurate mode on macOS 14 uses revision 3, which includes handwriting.
public enum VisionTextReader {
    public static func recognize(cgImage: CGImage) throws -> [TextObservation] {
        try recognize(VNImageRequestHandler(cgImage: cgImage, options: [:]))
    }

    public static func recognize(file url: URL) throws -> [TextObservation] {
        try recognize(VNImageRequestHandler(url: url, options: [:]))
    }

    private static func recognize(_ handler: VNImageRequestHandler) throws -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.revision = VNRecognizeTextRequestRevision3
        try handler.perform([request])
        var observations: [TextObservation] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            observations.append(TextObservation(
                text: text,
                box: NormalizedBox(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height),
                confidence: Double(candidate.confidence)
            ))
        }
        return observations
    }
}
#endif
