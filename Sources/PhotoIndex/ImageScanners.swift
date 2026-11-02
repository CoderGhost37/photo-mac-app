import Foundation

enum JPEGScanner {
    static func read(url: URL) -> ExtractedMetadata? {
        guard let header = readPrefix(url: url, limit: 2_000_000), header.count >= 4 else { return nil }
        return read(data: header)
    }

    static func read(data: Data) -> ExtractedMetadata? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        var offset = 2
        var result = ExtractedMetadata()
        var found = false
        while offset + 3 < bytes.count {
            while offset < bytes.count, bytes[offset] != 0xff {
                offset += 1
            }
            while offset < bytes.count, bytes[offset] == 0xff {
                offset += 1
            }
            guard offset < bytes.count else { break }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xd9 || marker == 0xda { break }
            if marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7) { continue }
            guard offset + 1 < bytes.count else { break }
            let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            guard length >= 2, offset + length <= bytes.count else { break }
            let payloadStart = offset + 2
            let payloadEnd = offset + length
            if marker == 0xe1, payloadEnd - payloadStart >= 6,
               bytes[payloadStart] == 0x45, bytes[payloadStart + 1] == 0x78,
               bytes[payloadStart + 2] == 0x69, bytes[payloadStart + 3] == 0x66,
               bytes[payloadStart + 4] == 0x00, bytes[payloadStart + 5] == 0x00 {
                let tiff = Data(bytes[payloadStart + 6..<payloadEnd])
                EXIFReader.apply(tiff: tiff, to: &result)
                found = true
            } else if isStartOfFrame(marker), payloadEnd - payloadStart >= 5 {
                let height = (Int(bytes[payloadStart + 1]) << 8) | Int(bytes[payloadStart + 2])
                let width = (Int(bytes[payloadStart + 3]) << 8) | Int(bytes[payloadStart + 4])
                if width > 0 { result.pixelWidth = width }
                if height > 0 { result.pixelHeight = height }
                found = true
            }
            offset += length
        }
        return found ? result : nil
    }

    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc
    }
}

enum PNGScanner {
    static func read(url: URL) -> ExtractedMetadata? {
        guard let data = readPrefix(url: url, limit: 64) else { return nil }
        return read(data: data)
    }

    static func read(data: Data) -> ExtractedMetadata? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= 24, Array(bytes.prefix(8)) == signature else { return nil }
        let type = String(bytes: bytes[12..<16], encoding: .ascii)
        guard type == "IHDR" else { return nil }
        let width = intBE(bytes, 16)
        let height = intBE(bytes, 20)
        guard width > 0, height > 0 else { return nil }
        return ExtractedMetadata(pixelWidth: width, pixelHeight: height)
    }

    private static func intBE(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }
}

enum MovieScanner {
    static func read(url: URL) -> ExtractedMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard end > 8 else { return nil }
        var meta = ExtractedMetadata()
        walk(handle: handle, start: 0, end: end, depth: 0, meta: &meta)
        return meta.hasValues ? meta : nil
    }

    private static func walk(
        handle: FileHandle,
        start: UInt64,
        end: UInt64,
        depth: Int,
        meta: inout ExtractedMetadata
    ) {
        guard depth < 8 else { return }
        var offset = start
        while offset &+ 8 <= end {
            guard let header = read(handle, offset, 16) else { return }
            let size32 = u32(header, 0)
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var headerSize: UInt64 = 8
            let boxSize: UInt64
            if size32 == 1 {
                guard header.count >= 16 else { return }
                boxSize = u64(header, 8)
                headerSize = 16
            } else if size32 == 0 {
                boxSize = end &- offset
            } else {
                boxSize = UInt64(size32)
            }
            guard boxSize >= headerSize, offset &+ boxSize <= end else { return }
            let payload = offset &+ headerSize
            let boxEnd = offset &+ boxSize
            switch type {
            case "moov", "trak", "mdia", "minf", "stbl":
                walk(handle: handle, start: payload, end: boxEnd, depth: depth + 1, meta: &meta)
            case "mvhd":
                parseMovieHeader(handle: handle, payload: payload, boxEnd: boxEnd, meta: &meta)
            case "tkhd":
                if boxSize >= 8, let tail = read(handle, boxEnd &- 8, 8), tail.count == 8 {
                    let width = Int(u32(tail, 0) >> 16)
                    let height = Int(u32(tail, 4) >> 16)
                    if width > 0 { meta.pixelWidth = width }
                    if height > 0 { meta.pixelHeight = height }
                }
            default:
                break
            }
            offset = boxEnd
        }
    }

    private static func parseMovieHeader(
        handle: FileHandle,
        payload: UInt64,
        boxEnd: UInt64,
        meta: inout ExtractedMetadata
    ) {
        guard let versionByte = read(handle, payload, 1), let version = versionByte.first else { return }
        if version == 0 {
            guard payload &+ 20 <= boxEnd, let fields = read(handle, payload &+ 12, 8), fields.count == 8 else { return }
            let timescale = u32(fields, 0)
            let duration = u32(fields, 4)
            if timescale > 0 {
                meta.duration = Double(duration) / Double(timescale)
            }
        } else if version == 1 {
            guard payload &+ 32 <= boxEnd, let fields = read(handle, payload &+ 20, 12), fields.count == 12 else { return }
            let timescale = u32(fields, 0)
            let duration = u64(fields, 4)
            if timescale > 0 {
                meta.duration = Double(duration) / Double(timescale)
            }
        }
    }

    private static func read(_ handle: FileHandle, _ offset: UInt64, _ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            return data.count == count ? data : nil
        } catch {
            return nil
        }
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data)
        return (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16) | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        (UInt64(u32(data, offset)) << 32) | UInt64(u32(data, offset + 4))
    }
}

func readPrefix(url: URL, limit: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: limit)
}
