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
