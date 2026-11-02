import Foundation

#if canImport(AVFoundation) && canImport(ImageIO)
import AVFoundation
import CoreGraphics
import ImageIO

public enum MovieEncodeProbe {
    public static func presetNames() -> Set<String> {
        Set(AVAssetExportSession.allExportPresets())
    }

    public static func hevcAvailability() -> EncodeAvailability {
        MovieEncodeTable.hevcAvailability(presetNames: presetNames())
    }
}

public enum MovieTranscoder {
    public static func export(
        input: URL,
        output: URL,
        format: ConvertFormat,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch format {
        case .mp4, .hevc, .m4a:
            try await exportSession(input: input, output: output, format: format, progress: progress)
        case .gif:
            try await writeGIF(input: input, output: output, progress: progress)
        case .jpeg, .png, .heic, .avif, .webp, .tiff:
            throw ConvertFailure.unsupported("\(format.title) is a still-image format.")
        }
    }

    private static func exportSession(
        input: URL,
        output: URL,
        format: ConvertFormat,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        if format == .m4a {
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw ConvertFailure.noAudio(input.lastPathComponent) }
        }
        let preset = try await presetName(for: format, asset: asset)
        let fileType = try fileType(for: format)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertFailure.exportFailed("Could not open \(input.lastPathComponent) for export.")
        }
        try await OutputNamer.writeAtomically(to: output) { partial in
            session.outputURL = partial
            session.outputFileType = fileType
            try await run(session, progress: progress, fileName: output.lastPathComponent)
        }
    }

    private static func presetName(for format: ConvertFormat, asset: AVAsset) async throws -> String {
        switch format {
        case .mp4:
            return AVAssetExportPresetHighestQuality
        case .m4a:
            return AVAssetExportPresetAppleM4A
        case .hevc:
            let compatible = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))
            guard compatible.contains(MovieEncodeTable.hevcPreset) else {
                throw ConvertFailure.unsupported("This Mac cannot encode HEVC. Choose MP4 instead.")
            }
            return MovieEncodeTable.hevcPreset
        default:
            throw ConvertFailure.unsupported("\(format.title) is not a video export.")
        }
    }

    private static func fileType(for format: ConvertFormat) throws -> AVFileType {
        switch format {
        case .mp4: return .mp4
        case .hevc: return .mov
        case .m4a: return .m4a
        default: throw ConvertFailure.unsupported("\(format.title) is not a video export.")
        }
    }

    private static func run(
        _ session: AVAssetExportSession,
        progress: @escaping @Sendable (Double) -> Void,
        fileName: String
    ) async throws {
        if Task.isCancelled { throw CancellationError() }
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        let message = session.error?.localizedDescription ?? "Could not write \(fileName)."
                        continuation.resume(throwing: ConvertFailure.exportFailed(message))
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }

    private static func writeGIF(
        input: URL,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let times = GIFSampling.plan(duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: GIFSampling.maxLongEdge, height: GIFSampling.maxLongEdge)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        var frames: [CGImage] = []
        for (index, time) in times.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let cm = CMTime(seconds: time, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: cm, actualTime: nil) {
                frames.append(image)
            }
            progress(Double(index + 1) / Double(max(times.count, 1)) * 0.8)
        }
        guard !frames.isEmpty else { throw ConvertFailure.unreadable(input.lastPathComponent) }
        let rows = ImageEncodeTable.availability(
            major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            minor: ProcessInfo.processInfo.operatingSystemVersion.minorVersion,
            destinationTypes: ImageEncodeProbe.destinationTypeIdentifiers()
        )
        if let gif = rows.first(where: { $0.format == .gif }), !gif.available {
            throw ConvertFailure.unsupported(gif.unavailableReason ?? "GIF cannot be written on this Mac.")
        }
        try OutputNamer.writeAtomically(to: output) { partial in
            try writeGIFFile(frames: frames, delay: GIFSampling.frameDelay, to: partial)
        }
        progress(1)
    }

    private static func writeGIFFile(frames: [CGImage], delay: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "com.compuserve.gif" as CFString,
            frames.count,
            nil
        ) else {
            throw ConvertFailure.unsupported("GIF cannot be written on this Mac.")
        }
        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: NSNumber(value: delay),
                kCGImagePropertyGIFUnclampedDelayTime: NSNumber(value: delay)
            ]
        ] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertFailure.exportFailed("Could not write \(url.lastPathComponent).")
        }
    }
}
#endif
