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
        let rows = ImageEncodeTable.availability(
            major: version.majorVersion,
            minor: version.minorVersion,
            destinationTypes: destinationTypeIdentifiers()
        )
        return WebPCodec.applyingEncoder(rows)
    }
}

public enum StillImageTranscoder {
    public static func convert(input: URL, output: URL, format: ConvertFormat) throws {
        guard let uti = format.imageDestinationUTI else {
            throw ConvertFailure.unsupported("\(format.title) is not a still-image format.")
        }
        let rows = ImageEncodeProbe.currentAvailability()
        guard let row = rows.first(where: { $0.format == format }), row.available else {
            let reason = rows.first(where: { $0.format == format })?.unavailableReason
                ?? "\(format.title) cannot be written on this Mac."
            throw ConvertFailure.unsupported(reason)
        }
        let image = try StillImageReader.orientedImage(at: input)
        if format == .webp {
            let data = try WebPImage.encode(image, quality: 85)
            try OutputNamer.writeAtomically(to: output) { partial in
                try data.write(to: partial)
            }
            return
        }
        try OutputNamer.writeAtomically(to: output) { partial in
            guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, uti as CFString, 1, nil) else {
                throw ConvertFailure.unsupported(row.unavailableReason ?? "\(format.title) cannot be written on this Mac.")
            }
            var properties: [CFString: Any] = [:]
            switch format {
            case .jpeg:
                properties[kCGImageDestinationLossyCompressionQuality] = NSNumber(value: 0.9)
            case .heic, .avif:
                properties[kCGImageDestinationLossyCompressionQuality] = NSNumber(value: 0.85)
            case .png, .tiff, .gif, .mp4, .hevc, .m4a, .webp:
                break
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConvertFailure.exportFailed("Could not write \(output.lastPathComponent).")
            }
        }
    }
}

enum WebPImage {
    static func encode(_ image: CGImage, quality: Float) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw ConvertFailure.unreadable("image")
        }
        let rgba = try straightRGBA(image, width: width, height: height)
        return try WebPCodec.encodeRGBA(width: width, height: height, rgba: rgba, quality: quality)
    }

    private static func straightRGBA(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw ConvertFailure.unsupported("Could not read pixels for WebP.")
        }
        var index = 0
        while index + 3 < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha == 0 {
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
            } else if alpha < 255 {
                pixels[index] = UInt8(min(255, Int(pixels[index]) * 255 / alpha))
                pixels[index + 1] = UInt8(min(255, Int(pixels[index + 1]) * 255 / alpha))
                pixels[index + 2] = UInt8(min(255, Int(pixels[index + 2]) * 255 / alpha))
            }
            index += 4
        }
        return pixels
    }
}
#endif
