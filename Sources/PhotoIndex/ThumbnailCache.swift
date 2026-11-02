import Foundation

/// Disk cache for generated thumbnails. The app fills it from QuickLook or PhotoKit.
public struct ThumbnailCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(assetID: String, maxPixel: Int, token: String) -> URL {
        directory.appendingPathComponent("\(safe(assetID))-\(maxPixel)-\(safe(token)).thumb")
    }

    public func existing(assetID: String, maxPixel: Int, token: String) -> URL? {
        let url = fileURL(assetID: assetID, maxPixel: maxPixel, token: token)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func store(_ data: Data, assetID: String, maxPixel: Int, token: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(assetID: assetID, maxPixel: maxPixel, token: token)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func invalidate(assetID: String) throws {
        let prefix = safe(assetID) + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func safe(_ value: String) -> String {
        let allowed = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "_"
        }
        let text = String(allowed)
        return text.isEmpty ? "asset" : text
    }
}
