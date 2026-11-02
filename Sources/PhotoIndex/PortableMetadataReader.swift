import Foundation

/// JPEG, PNG, and QuickTime metadata that does not need ImageIO or AVFoundation.
/// The Mac app prefers ImageIO and AVFoundation, and uses this to fill gaps.
public struct PortableMetadataReader: MetadataReading {
    public init() {}

    public func metadata(forFileAt url: URL) async -> ExtractedMetadata {
        metadataSync(forFileAt: url)
    }

    public func metadataSync(forFileAt url: URL) -> ExtractedMetadata {
        let ext = url.pathExtension.lowercased()
        if FileCatalog.videoExtensions.contains(ext) {
            return MovieScanner.read(url: url) ?? ExtractedMetadata()
        }
        if ext == "png" {
            return PNGScanner.read(url: url) ?? ExtractedMetadata()
        }
        if FileCatalog.imageExtensions.contains(ext) {
            return JPEGScanner.read(url: url) ?? PNGScanner.read(url: url) ?? ExtractedMetadata()
        }
        if let jpeg = JPEGScanner.read(url: url) { return jpeg }
        if let png = PNGScanner.read(url: url) { return png }
        if let movie = MovieScanner.read(url: url) { return movie }
        return ExtractedMetadata()
    }
}
