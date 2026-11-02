import Foundation

#if canImport(AVFoundation) && canImport(CoreGraphics)
import AVFoundation
import CoreGraphics

public enum VideoFrames {
    /// Up to `count` frames, spaced through the clip. A still image or a file with no duration yields nothing.
    public static func keyframes(at url: URL, count: Int) async throws -> [CGImage] {
        guard count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for index in 0..<count {
            let fraction = (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: min(seconds - 0.05, max(0, seconds * fraction)), preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: time)
                images.append(image)
            } catch {
                continue
            }
        }
        return images
    }
}
#endif
