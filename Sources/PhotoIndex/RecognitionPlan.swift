import Foundation

public struct RecognitionStamp: Equatable, Sendable {
    public var assetID: String
    public var mediaKind: MediaKind
    public var contentToken: String
    public var textToken: String?
    public var embeddingToken: String?
    public var embeddingModelID: String?

    public init(
        assetID: String,
        mediaKind: MediaKind,
        contentToken: String,
        textToken: String? = nil,
        embeddingToken: String? = nil,
        embeddingModelID: String? = nil
    ) {
        self.assetID = assetID
        self.mediaKind = mediaKind
        self.contentToken = contentToken
        self.textToken = textToken
        self.embeddingToken = embeddingToken
        self.embeddingModelID = embeddingModelID
    }
}

public enum ContentToken {
    public static func make(contentHash: String?, fileSize: Int64?, modifiedAt: Date?) -> String {
        if let contentHash {
            let trimmed = contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "h:\(trimmed)"
            }
        }
        let size = fileSize ?? -1
        let stamp = modifiedAt.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "none"
        return "t:\(size):\(stamp)"
    }
}

public enum RecognitionPlan {
    /// Still images are always eligible. Videos and screen recordings are included only when keyframes are on.
    public static func needsTextRecognition(_ stamps: [RecognitionStamp], includeVideoKeyframes: Bool) -> [String] {
        pending(stamps, includeVideoKeyframes: includeVideoKeyframes) { stamp in
            stamp.textToken != stamp.contentToken
        }
    }

    public static func needsEmbedding(_ stamps: [RecognitionStamp], modelID: String, includeVideoKeyframes: Bool) -> [String] {
        pending(stamps, includeVideoKeyframes: includeVideoKeyframes) { stamp in
            !(stamp.embeddingModelID == modelID && stamp.embeddingToken == stamp.contentToken)
        }
    }

    private static func pending(
        _ stamps: [RecognitionStamp],
        includeVideoKeyframes: Bool,
        needsWork: (RecognitionStamp) -> Bool
    ) -> [String] {
        stamps.compactMap { stamp in
            guard eligible(stamp.mediaKind, includeVideoKeyframes: includeVideoKeyframes), needsWork(stamp) else { return nil }
            return stamp.assetID
        }
        .sorted()
    }

    private static func eligible(_ kind: MediaKind, includeVideoKeyframes: Bool) -> Bool {
        switch kind {
        case .photo, .screenshot:
            return true
        case .video, .screenRecording:
            return includeVideoKeyframes
        }
    }
}
