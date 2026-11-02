import Foundation

/// OpenAI CLIP ViT-B/32.
///
/// The weights are MIT licensed (Copyright 2021 OpenAI) and are not in this
/// repository. `Scripts/fetch-clip.sh` downloads the published checkpoint,
/// checks its SHA-256, and converts it to a Core ML program for the CPU and
/// GPU. That program runs on Intel and Apple silicon. Stillroom never
/// downloads it. Apple's MobileCLIP weights are research-only, so they are
/// not used.
public enum ClipModel {
    public static let id = "openai-clip-vit-b32"
    public static let dimension = 512
    public static let contextLength = 77
    public static let imageSide = 224
    /// The OpenAI merge list has this many pairs after the header line.
    public static let bpeMergeCount = 48_894
    public static let directoryName = "openai-clip-vit-b32"
    public static let imageModelName = "ImageEncoder.mlmodelc"
    public static let textModelName = "TextEncoder.mlmodelc"
    public static let vocabularyName = "vocab.bpe"
    public static let checksumName = "checksums.sha256"

    public static func directory(home: URL) -> URL {
        IndexLocation.directory(home: home)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// A complete copy inside the app bundle wins. Otherwise the model lives in Application Support.
    public static func resolve(home: URL, bundle: Bundle? = nil) -> URL {
        if let bundle,
           let bundled = bundle.resourceURL?.appendingPathComponent(directoryName, isDirectory: true),
           ClipInstall.isComplete(directory: bundled) {
            return bundled
        }
        return directory(home: home)
    }
}

public enum ClipInstall {
    public static func isComplete(directory: URL) -> Bool {
        let names = [ClipModel.imageModelName, ClipModel.textModelName, ClipModel.vocabularyName, ClipModel.checksumName]
        return names.allSatisfy { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }
}

public enum ClipModelError: Error, Equatable, CustomStringConvertible {
    case incomplete
    case checksumMismatch([String])
    case unreadableModel(String)

    public var description: String {
        switch self {
        case .incomplete:
            return "The description model is not installed."
        case .checksumMismatch(let paths):
            return "The description model failed its checksum (\(paths.joined(separator: ", ")))."
        case .unreadableModel(let reason):
            return reason
        }
    }
}
