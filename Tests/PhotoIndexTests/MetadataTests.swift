import XCTest
@testable import PhotoIndex

final class MetadataTests: XCTestCase {
    func testSHA256KnownVectors() throws {
        var empty = SHA256Hasher()
        XCTAssertEqual(
            empty.finalizeHex(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        var abc = SHA256Hasher()
        abc.update(Data("abc".utf8))
        XCTAssertEqual(
            abc.finalizeHex(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-sha-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SHA256FileHasher().hash(ofFileAt: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testJPEGFixtureCarriesEXIFAndDimensions() throws {
        let url = try writeTemp(FixtureImages.jpeg(), name: "cabin.jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let meta = PortableMetadataReader().metadataSync(forFileAt: url)
        XCTAssertEqual(meta.pixelWidth, 80)
        XCTAssertEqual(meta.pixelHeight, 120)
        XCTAssertEqual(meta.cameraMake, "Canon")
        XCTAssertEqual(meta.cameraModel, "TestBody")
        XCTAssertEqual(meta.lensModel, "Test Lens")
        XCTAssertEqual(meta.iso, 200)
        XCTAssertEqual(meta.aperture ?? 0, 2.8, accuracy: 0.001)
        XCTAssertEqual(meta.shutterSpeed ?? 0, 1.0 / 125.0, accuracy: 0.00001)
        XCTAssertEqual(meta.focalLength ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(meta.latitude ?? 0, 37.8, accuracy: 0.0001)
        XCTAssertEqual(meta.longitude ?? 0, -122.4, accuracy: 0.0001)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(meta.createdAt))
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.month, 6)
        XCTAssertEqual(parts.day, 15)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.second, 0)
    }

    func testPNGFixtureReportsPixelSize() throws {
        let url = try writeTemp(FixtureImages.png(width: 320, height: 240), name: "frame.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let meta = PortableMetadataReader().metadataSync(forFileAt: url)
        XCTAssertEqual(meta.pixelWidth, 320)
        XCTAssertEqual(meta.pixelHeight, 240)
    }

    func testMovieFixtureReportsDurationAndSize() throws {
        let url = try writeTemp(FixtureImages.movie(width: 1920, height: 1080, timescale: 600, duration: 3000), name: "clip.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let meta = PortableMetadataReader().metadataSync(forFileAt: url)
        XCTAssertEqual(meta.duration ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(meta.pixelWidth, 1920)
        XCTAssertEqual(meta.pixelHeight, 1080)
    }
}

enum FixtureImages {
    static func jpeg() -> Data {
        let tiff = exifTIFF()
        var app1 = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        app1.append(tiff)
        var jpeg = Data([0xff, 0xd8])
        jpeg.append(marker(0xe1, app1))
        jpeg.append(marker(0xc0, Data([8, 0x00, 0x78, 0x00, 0x50, 1, 1, 0x11, 0x00])))
        jpeg.append(contentsOf: [0xff, 0xd9])
        return jpeg
    }

    static func png(width: UInt32, height: UInt32) -> Data {
        var ihdr = Data()
        ihdr.append(be32(width))
        ihdr.append(be32(height))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        var file = Data([137, 80, 78, 71, 13, 10, 26, 10])
        file.append(be32(UInt32(ihdr.count)))
        file.append(Data("IHDR".utf8))
        file.append(ihdr)
        file.append(be32(0))
        return file
    }

    static func movie(width: UInt32, height: UInt32, timescale: UInt32, duration: UInt32) -> Data {
        var mvhd = Data([0, 0, 0, 0])
        mvhd.append(be32(0))
        mvhd.append(be32(0))
        mvhd.append(be32(timescale))
        mvhd.append(be32(duration))
        mvhd.append(be32(0x0001_0000))
        mvhd.append(contentsOf: [0x01, 0x00])
        mvhd.append(Data(count: 10))
        for value in [UInt32(0x0001_0000), 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] {
            mvhd.append(be32(value))
        }
        mvhd.append(Data(count: 24))
        mvhd.append(be32(2))

        var tkhd = Data([0, 0, 0, 0])
        tkhd.append(Data(count: 72))
        tkhd.append(be32(width << 16))
        tkhd.append(be32(height << 16))

        var ftyp = Data("isom".utf8)
        ftyp.append(be32(0))
        ftyp.append(Data("isom".utf8))

        let moov = box("moov", box("mvhd", mvhd) + box("trak", box("tkhd", tkhd)))
        return box("ftyp", ftyp) + moov
    }

    private static func exifTIFF() -> Data {
        let ifd0Pos = 8
        let ifd0Size = 2 + 4 * 12 + 4
        let make = Data("Canon\0".utf8)
        let model = Data("TestBody\0".utf8)
        let exifPos = ifd0Pos + ifd0Size + make.count + model.count
        let exifSize = 2 + 6 * 12 + 4
        let date = Data("2024:06:15 14:30:00\0".utf8)
        let lens = Data("Test Lens\0".utf8)
        let exifBlob = date.count + 8 + 8 + 8 + lens.count
        let gpsPos = exifPos + exifSize + exifBlob
        let gpsSize = 2 + 4 * 12 + 4
        let blob0 = ifd0Pos + ifd0Size
        let exifBlobAt = exifPos + exifSize
        let dateAt = exifBlobAt
        let fNumberAt = dateAt + date.count
        let exposureAt = fNumberAt + 8
        let focalAt = exposureAt + 8
        let lensAt = focalAt + 8
        let gpsBlobAt = gpsPos + gpsSize
        let latAt = gpsBlobAt
        let lonAt = latAt + 24

        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2a, 0x00])
        appendU32(&data, UInt32(ifd0Pos))
        appendU16(&data, 4)
        entry(&data, tag: 271, type: 2, count: UInt32(make.count), value: UInt32(blob0))
        entry(&data, tag: 272, type: 2, count: UInt32(model.count), value: UInt32(blob0 + make.count))
        entry(&data, tag: 34_665, type: 4, count: 1, value: UInt32(exifPos))
        entry(&data, tag: 34_853, type: 4, count: 1, value: UInt32(gpsPos))
        appendU32(&data, 0)
        data.append(make)
        data.append(model)

        appendU16(&data, 6)
        entry(&data, tag: 33_434, type: 5, count: 1, value: UInt32(exposureAt))
        entry(&data, tag: 33_437, type: 5, count: 1, value: UInt32(fNumberAt))
        entry(&data, tag: 34_855, type: 3, count: 1, value: 200)
        entry(&data, tag: 36_867, type: 2, count: UInt32(date.count), value: UInt32(dateAt))
        entry(&data, tag: 37_386, type: 5, count: 1, value: UInt32(focalAt))
        entry(&data, tag: 42_036, type: 2, count: UInt32(lens.count), value: UInt32(lensAt))
        appendU32(&data, 0)
        data.append(date)
        data.append(rational(28, 10))
        data.append(rational(1, 125))
        data.append(rational(50, 1))
        data.append(lens)

        appendU16(&data, 4)
        entry(&data, tag: 1, type: 2, count: 2, value: UInt32("N".utf8.first!))
        entry(&data, tag: 2, type: 5, count: 3, value: UInt32(latAt))
        entry(&data, tag: 3, type: 2, count: 2, value: UInt32("W".utf8.first!))
        entry(&data, tag: 4, type: 5, count: 3, value: UInt32(lonAt))
        appendU32(&data, 0)
        data.append(rational(37, 1))
        data.append(rational(48, 1))
        data.append(rational(0, 1))
        data.append(rational(122, 1))
        data.append(rational(24, 1))
        data.append(rational(0, 1))

        precondition(exifPos == 77, "fixture layout drifted: \(exifPos)")
        precondition(data.count > lonAt)
        return data
    }

    private static func entry(_ data: inout Data, tag: UInt16, type: UInt16, count: UInt32, value: UInt32) {
        appendU16(&data, tag)
        appendU16(&data, type)
        appendU32(&data, count)
        appendU32(&data, value)
    }

    private static func rational(_ numerator: UInt32, _ denominator: UInt32) -> Data {
        var data = Data()
        appendU32(&data, numerator)
        appendU32(&data, denominator)
        return data
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }

    private static func marker(_ marker: UInt8, _ payload: Data) -> Data {
        var data = Data([0xff, marker])
        let length = UInt16(payload.count + 2)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xff))
        data.append(payload)
        return data
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = be32(UInt32(8 + payload.count))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }
}

func writeTemp(_ data: Data, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stillroom-\(UUID().uuidString)-\(name)")
    try data.write(to: url)
    return url
}
