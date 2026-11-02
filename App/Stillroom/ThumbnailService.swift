import AppKit
import Foundation
import PhotoIndex
import Photos
import QuickLookThumbnailing

/// Memory and disk thumbnails. Files go through Quick Look. Photos library
/// items go through `PHCachingImageManager` and are not downloaded for the grid.
@MainActor
final class ThumbnailService {
    enum Quality {
        case grid
        case preview
    }

    private let cache: ThumbnailCache
    private let memory = NSCache<NSString, NSImage>()
    private let photos = PHCachingImageManager()

    init(cache: ThumbnailCache) {
        self.cache = cache
        memory.countLimit = 500
        photos.allowsCachingHighQualityImages = true
    }

    func image(for asset: Asset, pointSize: CGFloat, scale: CGFloat, quality: Quality) async -> NSImage? {
        if Task.isCancelled { return nil }
        let pixel = max(40, Int((pointSize * max(scale, 1) / 40).rounded()) * 40)
        let token = asset.contentHash
            ?? asset.fileMTime.map { String(Int($0.timeIntervalSince1970)) }
            ?? "0"
        let key = "\(asset.id)|\(pixel)|\(token)|\(quality == .preview ? "p" : "g")" as NSString
        if let cached = memory.object(forKey: key) {
            return cached
        }
        if let url = cache.existing(assetID: asset.id, maxPixel: pixel, token: token),
           let image = NSImage(contentsOf: url) {
            memory.setObject(image, forKey: key)
            return image
        }

        let image: NSImage?
        if quality == .preview, let path = asset.filePath, (asset.fileSize ?? 0) < 25_000_000,
           asset.mediaKind == .photo || asset.mediaKind == .screenshot,
           let full = NSImage(contentsOfFile: path) {
            image = full
        } else if let localID = asset.photosLocalIdentifier {
            image = await photoImage(localIdentifier: localID, pixel: pixel, allowNetwork: quality == .preview)
        } else if let path = asset.filePath {
            image = await quickLookImage(path: path, pointSize: pointSize, scale: scale, quality: quality)
        } else {
            image = nil
        }

        guard let image, !Task.isCancelled else { return image }
        memory.setObject(image, forKey: key)
        if let data = jpegData(from: image) {
            let cache = cache
            let assetID = asset.id
            Task.detached(priority: .utility) {
                try? cache.store(data, assetID: assetID, maxPixel: pixel, token: token)
            }
        }
        return image
    }

    func preheat(localIdentifiers: [String], pixel: CGFloat) {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var items: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            items.append(asset)
        }
        guard !items.isEmpty else { return }
        let side = CGSize(width: pixel, height: pixel)
        photos.startCachingImages(for: items, targetSize: side, contentMode: .aspectFill, options: gridOptions(allowNetwork: false))
    }

    private func photoImage(localIdentifier: String, pixel: Int, allowNetwork: Bool) async -> NSImage? {
        guard let asset = PhotosLibraryClient.asset(localIdentifier: localIdentifier) else { return nil }
        let options = allowNetwork ? previewOptions() : gridOptions(allowNetwork: false)
        let side = CGSize(width: pixel, height: pixel)
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce()
            photos.requestImage(for: asset, targetSize: side, contentMode: .aspectFill, options: options) { image, _ in
                gate.run {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func quickLookImage(path: String, pointSize: CGFloat, scale: CGFloat, quality: Quality) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: pointSize, height: pointSize),
            scale: max(scale, 1),
            representationTypes: quality == .preview ? .thumbnail : .lowQualityThumbnail
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation.nsImage
        } catch {
            return nil
        }
    }

    private func gridOptions(allowNetwork: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false
        return options
    }

    private func previewOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }

    private func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
