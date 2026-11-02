import Foundation

#if canImport(ImageIO)
import ImageIO
import CoreGraphics

enum StillImageReader {
    static func orientedImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConvertFailure.unreadable(url.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ConvertFailure.unreadable(url.lastPathComponent)
        }
        var maxPixel = 1
        if let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = raw[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = raw[kCGImagePropertyPixelHeight] as? Int ?? 0
            maxPixel = max(width, height, 1)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: NSNumber(value: maxPixel)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConvertFailure.unreadable(url.lastPathComponent)
        }
        return image
    }
}

public enum ImageEncodeProbe {
    public static func destinationTypeIdentifiers() -> Set<String> {
        let array = CGImageDestinationCopyTypeIdentifiers() as NSArray
        return Set(array.compactMap { $0 as? String })
    }

    public static func currentAvailability() -> [EncodeAvailability] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ImageEncodeTable.availability(
            major: version.majorVersion,
            minor: version.minorVersion,
            destinationTypes: destinationTypeIdentifiers()
        )
    }
}

public enum StillImageTranscoder {
    public static func convert(input: URL, output: URL, format: ConvertFormat) throws {
        guard let uti = format.imageDestinationUTI else {
            throw ConvertFailure.unsupported("\(format.title) is not a still-image format.")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let rows = ImageEncodeTable.availability(
            major: version.majorVersion,
            minor: version.minorVersion,
            destinationTypes: ImageEncodeProbe.destinationTypeIdentifiers()
        )
        guard let row = rows.first(where: { $0.format == format }), row.available else {
            let reason = rows.first(where: { $0.format == format })?.unavailableReason
                ?? "\(format.title) cannot be written on this Mac."
            throw ConvertFailure.unsupported(reason)
        }
        let image = try StillImageReader.orientedImage(at: input)
        try OutputNamer.writeAtomically(to: output) { partial in
            guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, uti as CFString, 1, nil) else {
                throw ConvertFailure.unsupported(row.unavailableReason ?? "\(format.title) cannot be written on this Mac.")
            }
            var properties: [CFString: Any] = [:]
            switch format {
            case .jpeg:
                properties[kCGImageDestinationLossyCompressionQuality] = NSNumber(value: 0.9)
            case .heic, .avif, .webp:
                properties[kCGImageDestinationLossyCompressionQuality] = NSNumber(value: 0.85)
            case .png, .tiff, .gif, .mp4, .hevc, .m4a:
                break
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConvertFailure.exportFailed("Could not write \(output.lastPathComponent).")
            }
        }
    }
}
#endif
