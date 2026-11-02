import Foundation

/// One indexed photo, video, screenshot, or screen recording.
///
/// Identity is stable across rescans: file assets are keyed by source and
/// relative path, Photos library assets by `PHAsset.localIdentifier`.
public struct Asset: Identifiable, Equatable, Sendable {
    public var id: String
    public var sourceID: String
    public var filePath: String?
    public var photosLocalIdentifier: String?
    public var mediaKind: MediaKind
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var fileSize: Int64?
    public var duration: TimeInterval?
    public var latitude: Double?
    public var longitude: Double?
    /// City, region, or country already stored in the file. Nothing is looked up over the network.
    public var placeName: String?
    public var contentHash: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Int?
    public var aperture: Double?
    public var shutterSpeed: Double?
    public var focalLength: Double?
    public var fileMTime: Date?
    public var indexedAt: Date?

    public init(
        id: String,
        sourceID: String,
        filePath: String?,
        photosLocalIdentifier: String?,
        mediaKind: MediaKind,
        createdAt: Date?,
        modifiedAt: Date?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        fileSize: Int64?,
        duration: TimeInterval?,
        latitude: Double?,
        longitude: Double?,
        placeName: String? = nil,
        contentHash: String?,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Int? = nil,
        aperture: Double? = nil,
        shutterSpeed: Double? = nil,
        focalLength: Double? = nil,
        fileMTime: Date? = nil,
        indexedAt: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.filePath = filePath
        self.photosLocalIdentifier = photosLocalIdentifier
        self.mediaKind = mediaKind
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.duration = duration
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.contentHash = contentHash
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.focalLength = focalLength
        self.fileMTime = fileMTime
        self.indexedAt = indexedAt
    }
}

public enum AssetID {
    public static func file(sourceID: String, relativePath: String) -> String {
        "file:\(sourceID):\(relativePath)"
    }

    public static func photos(localIdentifier: String) -> String {
        "photos:\(localIdentifier)"
    }
}
