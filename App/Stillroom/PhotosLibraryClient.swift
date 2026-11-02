import CoreLocation
import Foundation
import PhotoIndex
import Photos

/// Read-only Photos library access. PhotoKit requires the readWrite access
/// level in order to read; this type never calls `PHPhotoLibrary.performChanges`.
enum PhotosLibraryClient {
    static func requestAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return current
    }

    static func fetchAssets() -> [Asset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        let result = PHAsset.fetchAssets(with: options)
        var assets: [Asset] = []
        assets.reserveCapacity(result.count)
        let indexedAt = Date()
        result.enumerateObjects { item, _, _ in
            guard item.mediaType == .image || item.mediaType == .video else { return }
            assets.append(makeAsset(item, indexedAt: indexedAt))
        }
        return assets
    }

    static func asset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Copies one library original into `directory`. The library itself is not changed.
    /// Network access stays off, so a photo that is only in iCloud is not downloaded.
    static func exportOriginal(localIdentifier: String, to directory: URL) async throws -> URL {
        guard let asset = asset(localIdentifier: localIdentifier) else {
            throw ConvertFailure.libraryUnreadable("a Photos item")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let order: [PHAssetResourceType] = [
            .photo, .video, .fullSizePhoto, .fullSizeVideo, .alternatePhoto, .fullSizePairedVideo
        ]
        let resource = order.compactMap { type in resources.first { $0.type == type } }.first ?? resources.first
        guard let resource else { throw ConvertFailure.libraryUnreadable("a Photos item") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension
        var reserved = Set<String>()
        let path = try OutputNamer.allocate(
            displayName: resource.originalFilename,
            sourcePath: nil,
            fileExtension: ext.isEmpty ? "dat" : ext,
            directory: directory.path,
            reserved: &reserved,
            exists: { FileManager.default.fileExists(atPath: $0) }
        ).get()
        let url = URL(fileURLWithPath: path)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConvertFailure.libraryUnreadable(resource.originalFilename)
        }
        return url
    }

    private static func makeAsset(_ item: PHAsset, indexedAt: Date) -> Asset {
        let kind: MediaKind
        if item.mediaSubtypes.contains(.photoScreenshot) {
            kind = .screenshot
        } else if item.mediaType == .video {
            kind = .video
        } else {
            kind = .photo
        }
        return Asset(
            id: AssetID.photos(localIdentifier: item.localIdentifier),
            sourceID: Source.photosLibraryID,
            filePath: nil,
            photosLocalIdentifier: item.localIdentifier,
            mediaKind: kind,
            createdAt: item.creationDate,
            modifiedAt: item.modificationDate,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            fileSize: nil,
            duration: item.mediaType == .video ? item.duration : nil,
            latitude: item.location?.coordinate.latitude,
            longitude: item.location?.coordinate.longitude,
            contentHash: nil,
            fileMTime: item.modificationDate,
            indexedAt: indexedAt
        )
    }
}
