import Foundation

#if canImport(ImageIO) || canImport(AVFoundation)
public struct AppleMetadataReader: MetadataReading {
    private let portable = PortableMetadataReader()

    public init() {}

    public func metadata(forFileAt url: URL) async -> ExtractedMetadata {
        let ext = url.pathExtension.lowercased()
        if FileCatalog.videoExtensions.contains(ext) {
            let portableMeta = portable.metadataSync(forFileAt: url)
            #if canImport(AVFoundation)
            if let movie = await AVMovieMetadata.read(url: url) {
                return movie.fillingGaps(from: portableMeta)
            }
            #endif
            return portableMeta
        }

        #if canImport(ImageIO)
        if let image = ImageIOMetadata.read(url: url), image.hasValues {
            return image
        }
        #endif
        return portable.metadataSync(forFileAt: url)
    }
}
#endif

#if canImport(ImageIO)
import ImageIO
import CoreGraphics

enum ImageIOMetadata {
    static func read(url: URL) -> ExtractedMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        guard let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else { return nil }
        let properties = raw as NSDictionary
        var meta = ExtractedMetadata()
        meta.pixelWidth = intValue(properties[kCGImagePropertyPixelWidth])
        meta.pixelHeight = intValue(properties[kCGImagePropertyPixelHeight])

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary {
            meta.cameraMake = stringValue(tiff[kCGImagePropertyTIFFMake])
            meta.cameraModel = stringValue(tiff[kCGImagePropertyTIFFModel])
            meta.createdAt = exifDate(stringValue(tiff[kCGImagePropertyTIFFDateTime])) ?? meta.createdAt
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary {
            meta.createdAt = exifDate(stringValue(exif[kCGImagePropertyExifDateTimeOriginal])) ?? meta.createdAt
            meta.lensModel = stringValue(exif[kCGImagePropertyExifLensModel])
            meta.iso = isoValue(exif[kCGImagePropertyExifISOSpeedRatings])
            meta.aperture = doubleValue(exif[kCGImagePropertyExifFNumber])
            meta.shutterSpeed = doubleValue(exif[kCGImagePropertyExifExposureTime])
            meta.focalLength = doubleValue(exif[kCGImagePropertyExifFocalLength])
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? NSDictionary {
            if let latitude = doubleValue(gps[kCGImagePropertyGPSLatitude]) {
                let ref = stringValue(gps[kCGImagePropertyGPSLatitudeRef])
                meta.latitude = ref?.uppercased() == "S" ? -abs(latitude) : abs(latitude)
            }
            if let longitude = doubleValue(gps[kCGImagePropertyGPSLongitude]) {
                let ref = stringValue(gps[kCGImagePropertyGPSLongitudeRef])
                meta.longitude = ref?.uppercased() == "W" ? -abs(longitude) : abs(longitude)
            }
        }
        meta.placeName = placeName(from: properties)
        return meta.hasValues ? meta : nil
    }

    private static func placeName(from properties: NSDictionary) -> String? {
        guard let iptc = properties[kCGImagePropertyIPTCDictionary] as? NSDictionary else { return nil }
        let keys = [
            kCGImagePropertyIPTCSubLocation,
            kCGImagePropertyIPTCCity,
            kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName
        ]
        var parts: [String] = []
        for key in keys {
            guard let value = stringValue(iptc[key]) else { continue }
            if !parts.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                parts.append(value)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func exifDate(_ string: String?) -> Date? {
        guard let string, string.count >= 19 else { return nil }
        let parts = string.prefix(19).split { $0 == ":" || $0 == " " }
        guard parts.count == 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Int(parts[5]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func isoValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let list = value as? [Any], let first = list.first as? NSNumber { return first.intValue }
        if let list = value as? NSArray, let first = list.firstObject as? NSNumber { return first.intValue }
        return nil
    }
}
#endif

#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics

enum AVMovieMetadata {
    static func read(url: URL) async -> ExtractedMetadata? {
        let asset = AVURLAsset(url: url)
        var meta = ExtractedMetadata()
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                meta.duration = seconds
            }
        }
        if let creation = try? await asset.load(.creationDate),
           let date = try? await creation.load(.dateValue) {
            meta.createdAt = date
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video) {
            for track in tracks {
                guard let size = try? await track.load(.naturalSize) else { break }
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                let width = Int(abs(rect.width).rounded())
                let height = Int(abs(rect.height).rounded())
                if width > 0 { meta.pixelWidth = width }
                if height > 0 { meta.pixelHeight = height }
                break
            }
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            let locations = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierLocation
            )
            if let value = try? await locations.first?.load(.stringValue) {
                applyISO6709(value, to: &meta)
            }
        }
        return meta.hasValues ? meta : nil
    }

    /// ISO 6709 strings look like `+37.8000-122.4000/` or `+37.8000-122.4000+012.000/`.
    static func applyISO6709(_ value: String, to metadata: inout ExtractedMetadata) {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let regex = try? NSRegularExpression(pattern: "([+-]\\d+(?:\\.\\d+)?)([+-]\\d+(?:\\.\\d+)?)") else { return }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges >= 3,
              let latRange = Range(match.range(at: 1), in: trimmed),
              let lonRange = Range(match.range(at: 2), in: trimmed),
              let latitude = Double(trimmed[latRange]),
              let longitude = Double(trimmed[lonRange]) else {
            return
        }
        metadata.latitude = latitude
        metadata.longitude = longitude
    }
}
#endif
