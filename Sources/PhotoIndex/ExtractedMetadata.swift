import Foundation

public struct ExtractedMetadata: Equatable, Sendable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var createdAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var duration: TimeInterval?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Int?
    public var aperture: Double?
    public var shutterSpeed: TimeInterval?
    public var focalLength: Double?

    public init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        createdAt: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        duration: TimeInterval? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Int? = nil,
        aperture: Double? = nil,
        shutterSpeed: TimeInterval? = nil,
        focalLength: Double? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        self.latitude = latitude
        self.longitude = longitude
        self.duration = duration
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.focalLength = focalLength
    }

    public var hasValues: Bool {
        pixelWidth != nil || pixelHeight != nil || createdAt != nil || latitude != nil
            || longitude != nil || duration != nil || cameraMake != nil || cameraModel != nil
            || lensModel != nil || iso != nil || aperture != nil || shutterSpeed != nil
            || focalLength != nil
    }

    public func fillingGaps(from other: ExtractedMetadata) -> ExtractedMetadata {
        var copy = self
        if copy.pixelWidth == nil { copy.pixelWidth = other.pixelWidth }
        if copy.pixelHeight == nil { copy.pixelHeight = other.pixelHeight }
        if copy.createdAt == nil { copy.createdAt = other.createdAt }
        if copy.latitude == nil { copy.latitude = other.latitude }
        if copy.longitude == nil { copy.longitude = other.longitude }
        if copy.duration == nil { copy.duration = other.duration }
        if copy.cameraMake == nil { copy.cameraMake = other.cameraMake }
        if copy.cameraModel == nil { copy.cameraModel = other.cameraModel }
        if copy.lensModel == nil { copy.lensModel = other.lensModel }
        if copy.iso == nil { copy.iso = other.iso }
        if copy.aperture == nil { copy.aperture = other.aperture }
        if copy.shutterSpeed == nil { copy.shutterSpeed = other.shutterSpeed }
        if copy.focalLength == nil { copy.focalLength = other.focalLength }
        return copy
    }
}

public protocol MetadataReading: Sendable {
    func metadata(forFileAt url: URL) async -> ExtractedMetadata
}
