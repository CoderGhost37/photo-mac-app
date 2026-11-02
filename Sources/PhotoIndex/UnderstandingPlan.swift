import Foundation

public struct UnderstandingStamp: Equatable, Sendable {
    public var assetID: String
    public var mediaKind: MediaKind
    public var contentToken: String
    public var scannedToken: String?

    public init(assetID: String, mediaKind: MediaKind, contentToken: String, scannedToken: String? = nil) {
        self.assetID = assetID
        self.mediaKind = mediaKind
        self.contentToken = contentToken
        self.scannedToken = scannedToken
    }
}

public enum UnderstandingPlan {
    /// Still photos and screenshots are read once per content token. Video is skipped.
    public static func needsScan(_ stamps: [UnderstandingStamp]) -> [String] {
        stamps.compactMap { stamp in
            guard stamp.mediaKind == .photo || stamp.mediaKind == .screenshot else { return nil }
            guard stamp.scannedToken != stamp.contentToken else { return nil }
            return stamp.assetID
        }
        .sorted()
    }
}
