import CoreGraphics
import Foundation
import PhotoIndex

/// Reads text and image embeddings after indexing. The queue uses background QoS.
final class RecognitionService: @unchecked Sendable {
    private let database: IndexDatabase
    private let queue = DispatchQueue(label: "Stillroom.Recognition", qos: .background)
    private let modelLock = NSLock()
    private var embedder: CoreMLClipEmbedder?
    private var embedderStamp: String?
    private var draining = false
    private var again = false
    private var includeVideo = false
    private let home: URL
    private let workDirectory: URL
    private let pauseReason: @Sendable () -> BackgroundPauseReason?
    var onProgress: @Sendable (String?) -> Void = { _ in }

    init(
        database: IndexDatabase,
        home: URL,
        pauseReason: @escaping @Sendable () -> BackgroundPauseReason? = { nil }
    ) {
        self.database = database
        self.home = home
        self.pauseReason = pauseReason
        self.workDirectory = IndexLocation.workDirectory(home: home)
            .appendingPathComponent("Recognition", isDirectory: true)
    }

    func schedule(includeVideoKeyframes: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.includeVideo = includeVideoKeyframes
            if self.draining {
                self.again = true
                return
            }
            self.drain()
        }
    }

    func queryVector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedder = loadEmbedder() else { return nil }
        return try? embedder.embed(text: trimmed)
    }

    private func drain() {
        draining = true
        defer {
            draining = false
            if again {
                again = false
                drain()
            }
        }
        let includeVideoKeyframes = includeVideo
        guard let stamps = try? database.recognitionStamps() else { return }
        let textIDs = Set(RecognitionPlan.needsTextRecognition(stamps, includeVideoKeyframes: includeVideoKeyframes))
        let embedder = loadEmbedder()
        let embedIDs = embedder == nil
            ? Set<String>()
            : Set(RecognitionPlan.needsEmbedding(stamps, modelID: ClipModel.id, includeVideoKeyframes: includeVideoKeyframes))
        let ordered = stamps.map(\.assetID).filter { textIDs.contains($0) || embedIDs.contains($0) }.sorted()
        guard !ordered.isEmpty else { return }
        var remaining = ordered.count
        for id in ordered {
            waitWhilePaused()
            if again { break }
            remaining -= 1
            if remaining % 20 == 0 {
                onProgress("Reading text · \(remaining) left")
            }
            guard let asset = try? database.asset(id: id) else { continue }
            let token = ContentToken.make(contentHash: asset.contentHash, fileSize: asset.fileSize, modifiedAt: asset.fileMTime)
            let material = materialize(asset)
            defer {
                if let material, material.temporary {
                    try? FileManager.default.removeItem(at: material.url)
                }
            }
            if textIDs.contains(id) {
                let observations = material.map { readText(asset: asset, url: $0.url, includeVideo: includeVideoKeyframes) } ?? []
                try? database.replaceTextHits(assetID: id, contentToken: token, observations: observations)
            }
            if embedIDs.contains(id), let embedder, let material,
               let values = embed(asset: asset, url: material.url, embedder: embedder, includeVideo: includeVideoKeyframes) {
                try? database.saveEmbedding(
                    assetID: id,
                    modelID: ClipModel.id,
                    values: values,
                    contentToken: token
                )
            }
        }
        onProgress(nil)
    }

    private func waitWhilePaused() {
        while let reason = pauseReason() {
            if again { return }
            onProgress(BackgroundPause.message(reason))
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func loadEmbedder() -> CoreMLClipEmbedder? {
        let directory = ClipModel.resolve(home: home, bundle: .main)
        let stamp = directoryStamp(directory)
        modelLock.lock()
        defer { modelLock.unlock() }
        if embedderStamp == stamp { return embedder }
        embedderStamp = stamp
        embedder = try? CoreMLClipEmbedder(directory: directory)
        return embedder
    }

    private func directoryStamp(_ directory: URL) -> String {
        guard ClipInstall.isComplete(directory: directory) else { return "missing" }
        let names = [ClipModel.imageModelName, ClipModel.textModelName, ClipModel.vocabularyName, ClipModel.checksumName]
        return names.map { name in
            let path = directory.appendingPathComponent(name).path
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(modified)"
        }.joined(separator: "|")
    }

    private func materialize(_ asset: Asset) -> Material? {
        if let path = asset.filePath {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Material(url: URL(fileURLWithPath: path), temporary: false)
        }
        guard let identifier = asset.photosLocalIdentifier else { return nil }
        let directory = workDirectory
        let group = DispatchGroup()
        group.enter()
        var exported: URL?
        Task {
            exported = try? await PhotosLibraryClient.exportOriginal(localIdentifier: identifier, to: directory)
            group.leave()
        }
        group.wait()
        guard let exported else { return nil }
        return Material(url: exported, temporary: true)
    }

    private func readText(asset: Asset, url: URL, includeVideo: Bool) -> [TextObservation] {
        if asset.mediaKind == .video || asset.mediaKind == .screenRecording {
            guard includeVideo else { return [] }
            return frames(at: url).flatMap { frame in
                (try? VisionTextReader.recognize(cgImage: frame)) ?? []
            }
        }
        return (try? VisionTextReader.recognize(file: url)) ?? []
    }

    private func embed(asset: Asset, url: URL, embedder: CoreMLClipEmbedder, includeVideo: Bool) -> [Float]? {
        if asset.mediaKind == .video || asset.mediaKind == .screenRecording {
            guard includeVideo else { return nil }
            let sampled = frames(at: url)
            guard !sampled.isEmpty else { return nil }
            return try? embedder.embed(cgImage: sampled[sampled.count / 2])
        }
        return try? embedder.embed(file: url)
    }

    private func frames(at url: URL) -> [CGImage] {
        let group = DispatchGroup()
        group.enter()
        var images: [CGImage] = []
        Task {
            images = (try? await VideoFrames.keyframes(at: url, count: 4)) ?? []
            group.leave()
        }
        group.wait()
        return images
    }
}

private struct Material {
    var url: URL
    var temporary: Bool
}
