import Foundation

/// Reads the EXIF TIFF block that follows the `Exif\0\0` prefix in a JPEG APP1 segment.
enum EXIFReader {
    private static let tagExifIFD: UInt16 = 34_665
    private static let tagGPSIFD: UInt16 = 34_853
    private static let tagMake: UInt16 = 271
    private static let tagModel: UInt16 = 272
    private static let tagDateTime: UInt16 = 306
    private static let tagDateTimeOriginal: UInt16 = 36_867
    private static let tagDateTimeDigitized: UInt16 = 36_868
    private static let tagISO: UInt16 = 34_855
    private static let tagFNumber: UInt16 = 33_437
    private static let tagExposureTime: UInt16 = 33_434
    private static let tagFocalLength: UInt16 = 37_386
    private static let tagLensModel: UInt16 = 42_036
    private static let tagGPSLatRef: UInt16 = 1
    private static let tagGPSLat: UInt16 = 2
    private static let tagGPSLonRef: UInt16 = 3
    private static let tagGPSLon: UInt16 = 4

    static func apply(tiff: Data, to metadata: inout ExtractedMetadata) {
        let bytes = [UInt8](tiff)
        guard bytes.count >= 8 else { return }
        let little: Bool
        if bytes[0] == 0x49, bytes[1] == 0x49 {
            little = true
        } else if bytes[0] == 0x4d, bytes[1] == 0x4d {
            little = false
        } else {
            return
        }
        guard u16(bytes, 2, little) == 42 else { return }

        var exifDate: Date?
        var digitized: Date?
        var rootDate: Date?
        var latitude: Double?
        var longitude: Double?
        var latitudeRef: String?
        var longitudeRef: String?

        let ifd0 = Int(u32(bytes, 4, little))
        walk(bytes: bytes, ifd: ifd0, little: little, depth: 0) { tag, type, count, value in
            switch tag {
            case tagMake:
                metadata.cameraMake = ascii(value)
            case tagModel:
                metadata.cameraModel = ascii(value)
            case tagLensModel:
                metadata.lensModel = ascii(value)
            case tagDateTime:
                rootDate = date(from: ascii(value))
            case tagDateTimeOriginal:
                exifDate = date(from: ascii(value))
            case tagDateTimeDigitized:
                digitized = date(from: ascii(value))
            case tagISO:
                if let iso = integer(type: type, count: count, value: value, little: little) {
                    metadata.iso = iso
                }
            case tagFNumber:
                metadata.aperture = firstRational(value, little: little)
            case tagExposureTime:
                metadata.shutterSpeed = firstRational(value, little: little)
            case tagFocalLength:
                metadata.focalLength = firstRational(value, little: little)
            case tagGPSLat:
                latitude = dms(value, little: little)
            case tagGPSLon:
                longitude = dms(value, little: little)
            case tagGPSLatRef:
                latitudeRef = ascii(value)
            case tagGPSLonRef:
                longitudeRef = ascii(value)
            default:
                break
            }
        }

        metadata.createdAt = exifDate ?? digitized ?? rootDate ?? metadata.createdAt
        if let latitude {
            metadata.latitude = signed(latitude, reference: latitudeRef, negative: "S")
        }
        if let longitude {
            metadata.longitude = signed(longitude, reference: longitudeRef, negative: "W")
        }
    }

    private static func walk(
        bytes: [UInt8],
        ifd: Int,
        little: Bool,
        depth: Int,
        visit: (UInt16, UInt16, UInt32, [UInt8]) -> Void
    ) {
        guard depth < 4, ifd >= 0, ifd + 2 <= bytes.count else { return }
        let count = Int(u16(bytes, ifd, little))
        guard count < 10_000 else { return }
        for index in 0..<count {
            let entry = ifd + 2 + index * 12
            guard entry + 12 <= bytes.count else { return }
            let tag = u16(bytes, entry, little)
            let type = u16(bytes, entry + 2, little)
            let valueCount = u32(bytes, entry + 4, little)
            let value = valueBytes(bytes: bytes, entry: entry, type: type, count: valueCount, little: little)
            if tag == tagExifIFD || tag == tagGPSIFD,
               let pointer = integer(type: type, count: valueCount, value: value, little: little) {
                walk(bytes: bytes, ifd: pointer, little: little, depth: depth + 1, visit: visit)
            } else {
                visit(tag, type, valueCount, value)
            }
        }
    }

    private static func valueBytes(bytes: [UInt8], entry: Int, type: UInt16, count: UInt32, little: Bool) -> [UInt8] {
        let total = unitSize(type) * Int(count)
        guard total > 0, total < 8_000_000 else { return [] }
        if total <= 4 {
            return Array(bytes[entry + 8..<min(entry + 8 + total, bytes.count)])
        }
        let offset = Int(u32(bytes, entry + 8, little))
        guard offset >= 0, offset + total <= bytes.count else { return [] }
        return Array(bytes[offset..<offset + total])
    }

    private static func unitSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9: return 4
        case 5, 10: return 8
        default: return 1
        }
    }

    private static func ascii(_ bytes: [UInt8]) -> String? {
        let trimmed = bytes.prefix { $0 != 0 }
        guard !trimmed.isEmpty, let string = String(bytes: trimmed, encoding: .utf8) else { return nil }
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// EXIF timestamps have no time zone. They are stored so the clock numbers
    /// match the camera when formatted in the local time zone.
    private static func date(from string: String?) -> Date? {
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

    private static func integer(type: UInt16, count: UInt32, value: [UInt8], little: Bool) -> Int? {
        guard count >= 1 else { return nil }
        switch type {
        case 1, 7:
            return value.first.map(Int.init)
        case 3:
            guard value.count >= 2 else { return nil }
            return Int(u16(value, 0, little))
        case 4:
            guard value.count >= 4 else { return nil }
            return Int(u32(value, 0, little))
        default:
            return nil
        }
    }

    private static func firstRational(_ value: [UInt8], little: Bool) -> Double? {
        guard value.count >= 8 else { return nil }
        let numerator = u32(value, 0, little)
        let denominator = u32(value, 4, little)
        guard denominator != 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    private static func dms(_ value: [UInt8], little: Bool) -> Double? {
        guard value.count >= 24 else { return nil }
        func component(_ index: Int) -> Double {
            let offset = index * 8
            let numerator = u32(value, offset, little)
            let denominator = u32(value, offset + 4, little)
            guard denominator != 0 else { return 0 }
            return Double(numerator) / Double(denominator)
        }
        return component(0) + component(1) / 60 + component(2) / 3600
    }

    private static func signed(_ degrees: Double, reference: String?, negative: String) -> Double {
        if reference?.uppercased().hasPrefix(negative) == true {
            return -abs(degrees)
        }
        return abs(degrees)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int, _ little: Bool) -> UInt16 {
        let low = UInt16(bytes[offset])
        let high = UInt16(bytes[offset + 1])
        return little ? (high << 8) | low : (low << 8) | high
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int, _ little: Bool) -> UInt32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        if little {
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
