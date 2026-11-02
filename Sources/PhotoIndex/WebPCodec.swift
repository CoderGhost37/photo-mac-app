import Foundation
import WebP

public enum WebPCodecError: Error, Equatable {
    case invalidImage
}

/// Encodes and decodes WebP with libwebp. ImageIO can read WebP and still cannot write it.
public enum WebPCodec {
    public static func encodeRGBA(width: Int, height: Int, rgba: [UInt8], quality: Float) throws -> Data {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            throw WebPCodecError.invalidImage
        }
        let image = WebP(width: width, height: height, rgba: rgba)
        let bytes = try image.encode(quality: quality)
        guard !bytes.isEmpty else { throw WebPCodecError.invalidImage }
        return Data(bytes)
    }

    public static func decodeRGBA(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let image = try WebP.decode([UInt8](data))
        return (image.width, image.height, image.rgba)
    }

    /// WebP is available because libwebp is linked, whatever ImageIO lists.
    public static func applyingEncoder(_ rows: [EncodeAvailability]) -> [EncodeAvailability] {
        rows.map { row in
            guard row.format == .webp else { return row }
            return EncodeAvailability(format: .webp, available: true, unavailableReason: nil)
        }
    }
}
