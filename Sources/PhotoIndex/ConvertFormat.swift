import Foundation

/// Formats the convert panel can write. Encoding support is a separate question:
/// ImageIO does not write every format it can read.
public enum ConvertFormat: String, CaseIterable, Sendable, Equatable, Identifiable {
    case jpeg
    case png
    case heic
    case avif
    case webp
    case tiff
    case mp4
    case hevc
    case gif
    case m4a

    public var id: String { rawValue }

    public static let stillTargets: [ConvertFormat] = [.jpeg, .png, .heic, .avif, .webp, .tiff]
    public static let videoTargets: [ConvertFormat] = [.mp4, .hevc, .gif, .m4a]

    public var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .webp: return "WebP"
        case .tiff: return "TIFF"
        case .mp4: return "MP4"
        case .hevc: return "HEVC"
        case .gif: return "GIF"
        case .m4a: return "M4A"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .avif: return "avif"
        case .webp: return "webp"
        case .tiff: return "tiff"
        case .mp4: return "mp4"
        case .hevc: return "mov"
        case .gif: return "gif"
        case .m4a: return "m4a"
        }
    }

    /// ImageIO destination UTI for stills, including a one-frame GIF.
    public var imageDestinationUTI: String? {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .webp: return "org.webmproject.webp"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .mp4, .hevc, .m4a: return nil
        }
    }

    public var acceptsStillImage: Bool {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff, .gif: return true
        case .mp4, .hevc, .m4a: return false
        }
    }

    public var acceptsVideo: Bool {
        switch self {
        case .mp4, .hevc, .gif, .m4a: return true
        case .jpeg, .png, .heic, .avif, .webp, .tiff: return false
        }
    }

    public var detail: String {
        switch self {
        case .hevc: return "HEVC video in a MOV file."
        case .m4a: return "The audio track, written as M4A."
        case .gif: return "A still image, or a short animation from video."
        case .mp4: return "H.264 video in an MP4 file."
        default: return title
        }
    }
}

public enum ConvertSourceKind: String, Sendable, Equatable {
    case image
    case video
    case unsupported
}

public enum ConvertRouting {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "avif", "dng", "jp2"
    ]
    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv"
    ]

    public static func kind(fileExtension: String) -> ConvertSourceKind {
        let ext = fileExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return .unsupported
    }

    public static func allows(_ format: ConvertFormat, fileExtension: String) -> Bool {
        switch kind(fileExtension: fileExtension) {
        case .image: return format.acceptsStillImage
        case .video: return format.acceptsVideo
        case .unsupported: return false
        }
    }

    public static func formats(for fileExtension: String) -> [ConvertFormat] {
        ConvertFormat.allCases.filter { allows($0, fileExtension: fileExtension) }
    }

    /// Nil when this file can be written as `format`.
    public static func rejection(fileName: String, fileExtension: String, format: ConvertFormat) -> String? {
        if allows(format, fileExtension: fileExtension) { return nil }
        switch kind(fileExtension: fileExtension) {
        case .image:
            return "\(fileName) is a still image. \(format.title) is \(format.role)."
        case .video:
            return "\(fileName) is a video. \(format.title) is \(format.role)."
        case .unsupported:
            return "\(fileName) is not a photo or video that can be converted."
        }
    }
}

extension ConvertFormat {
    fileprivate var role: String {
        switch self {
        case .jpeg, .png, .heic, .avif, .webp, .tiff:
            return "a still-image format"
        case .gif:
            return "for a still image or a video"
        case .mp4, .hevc:
            return "a video format"
        case .m4a:
            return "an audio extract from video"
        }
    }
}

public struct EncodeAvailability: Equatable, Sendable {
    public var format: ConvertFormat
    public var available: Bool
    public var unavailableReason: String?

    public init(format: ConvertFormat, available: Bool, unavailableReason: String?) {
        self.format = format
        self.available = available
        self.unavailableReason = available ? nil : unavailableReason
    }
}

/// Which still formats ImageIO can write.
///
/// WebP has been readable since macOS 11, and ImageIO still does not advertise a WebP writer.
/// Stillroom writes WebP with libwebp instead; `ImageEncodeProbe` reports that separately.
/// AVIF writing arrived in macOS 26. When `destinationTypes` is provided it wins, so a system
/// that lists the UTI is offered the format even if this table is older than that system.
public enum ImageEncodeTable {
    public struct Rule: Equatable, Sendable {
        public var format: ConvertFormat
        public var uti: String
        /// First macOS release known to encode this UTI. Nil means none is known to.
        public var major: Int?
        public var minor: Int

        public init(format: ConvertFormat, uti: String, major: Int?, minor: Int = 0) {
            self.format = format
            self.uti = uti
            self.major = major
            self.minor = minor
        }
    }

    public static let rules: [Rule] = [
        Rule(format: .jpeg, uti: "public.jpeg", major: 10),
        Rule(format: .png, uti: "public.png", major: 10),
        Rule(format: .heic, uti: "public.heic", major: 10, minor: 13),
        Rule(format: .tiff, uti: "public.tiff", major: 10),
        Rule(format: .gif, uti: "com.compuserve.gif", major: 10),
        Rule(format: .webp, uti: "org.webmproject.webp", major: nil),
        Rule(format: .avif, uti: "public.avif", major: 26)
    ]

    public static func availability(
        major systemMajor: Int,
        minor systemMinor: Int,
        destinationTypes: Set<String>?
    ) -> [EncodeAvailability] {
        rules.map { rule in
            one(rule, major: systemMajor, minor: systemMinor, destinationTypes: destinationTypes)
        }
    }

    private static func one(
        _ rule: Rule,
        major systemMajor: Int,
        minor systemMinor: Int,
        destinationTypes: Set<String>?
    ) -> EncodeAvailability {
        let versionOK = meets(rule, major: systemMajor, minor: systemMinor)
        if let destinationTypes {
            if destinationTypes.contains(rule.uti) {
                return EncodeAvailability(format: rule.format, available: true, unavailableReason: nil)
            }
            return EncodeAvailability(
                format: rule.format,
                available: false,
                unavailableReason: missing(rule, versionOK: versionOK)
            )
        }
        if versionOK {
            return EncodeAvailability(format: rule.format, available: true, unavailableReason: nil)
        }
        return EncodeAvailability(
            format: rule.format,
            available: false,
            unavailableReason: missing(rule, versionOK: false)
        )
    }

    private static func meets(_ rule: Rule, major: Int, minor: Int) -> Bool {
        guard let required = rule.major else { return false }
        if major != required { return major > required }
        return minor >= rule.minor
    }

    private static func missing(_ rule: Rule, versionOK: Bool) -> String {
        switch rule.format {
        case .webp:
            return "ImageIO on this Mac can open WebP files but cannot write them. Choose JPEG, PNG, HEIC, or TIFF."
        case .avif:
            if versionOK {
                return "ImageIO on this Mac does not list AVIF as a format it can write."
            }
            return "AVIF encoding needs macOS 26 or later. ImageIO on this Mac does not offer it."
        default:
            let version = "\(rule.major ?? 0).\(rule.minor)"
            return "\(rule.format.title) encoding needs macOS \(version) or later."
        }
    }
}

public enum MovieEncodeTable {
    /// `AVAssetExportPresetHEVCHighestQuality`. Passed as a string so tests do not import AVFoundation.
    public static let hevcPreset = "AVAssetExportPresetHEVCHighestQuality"

    /// `presetNames` nil means the machine was not asked. A set that omits the HEVC preset means this Mac cannot write it.
    public static func hevcAvailability(presetNames: Set<String>?) -> EncodeAvailability {
        if let presetNames, !presetNames.contains(hevcPreset) {
            return EncodeAvailability(
                format: .hevc,
                available: false,
                unavailableReason: "This Mac cannot encode HEVC. Choose MP4 instead."
            )
        }
        return EncodeAvailability(format: .hevc, available: true, unavailableReason: nil)
    }
}

public enum ConvertFailure: Error, Equatable, LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case noAudio(String)
    case exportFailed(String)
    case libraryUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Could not read \(name)."
        case .unsupported(let reason):
            return reason
        case .noAudio(let name):
            return "\(name) has no audio track to extract."
        case .exportFailed(let reason):
            return reason
        case .libraryUnreadable(let name):
            return "Could not read \(name) from the Photos library. Nothing was written."
        }
    }
}
