import Foundation

public struct DeviceFile: Equatable, Sendable {
    public var name: String
    public var byteSize: Int64
    public var createdAt: Date?

    public init(name: String, byteSize: Int64, createdAt: Date?) {
        self.name = name
        self.byteSize = byteSize
        self.createdAt = createdAt
    }

    /// Stable across reconnects. Camera object handles are not part of it.
    public var signature: String {
        let stamp: String
        if let createdAt {
            stamp = String(Int(createdAt.timeIntervalSince1970.rounded()))
        } else {
            stamp = "none"
        }
        return "\(DeviceImportPlan.fileName(name))|\(byteSize)|\(stamp)"
    }
}

public struct ImportDecision: Equatable, Sendable {
    public var file: DeviceFile
    public var relativePath: String
    public var skip: Bool

    public init(file: DeviceFile, relativePath: String, skip: Bool) {
        self.file = file
        self.relativePath = relativePath
        self.skip = skip
    }
}

/// The copy ImageCaptureCore is asked to perform. Deletion is always off.
public struct DeviceDownloadRequest: Equatable, Sendable {
    public var directoryPath: String
    public var fileName: String
    public var overwrite: Bool
    public var deleteAfterDownload: Bool
    public var includeSidecars: Bool

    public init(
        directoryPath: String,
        fileName: String,
        overwrite: Bool,
        deleteAfterDownload: Bool,
        includeSidecars: Bool
    ) {
        self.directoryPath = directoryPath
        self.fileName = fileName
        self.overwrite = overwrite
        self.deleteAfterDownload = deleteAfterDownload
        self.includeSidecars = includeSidecars
    }
}

public enum DeviceImportPlan {
    public static func monthDirectory(createdAt: Date?, calendar: Calendar) -> String {
        guard let createdAt else { return "undated" }
        let year = calendar.component(.year, from: createdAt)
        let month = calendar.component(.month, from: createdAt)
        return String(format: "%04d/%02d", year, month)
    }

    public static func fileName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "\\", with: "/")
        let base = URL(fileURLWithPath: cleaned).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { return "photo" }
        return base
    }

    /// Copies land in `YYYY/MM`. A file already imported, or already sitting at that path with the same size, is skipped.
    /// A different size gets `name 2.ext`. Nothing in the plan deletes the camera file.
    public static func plan(
        files: [DeviceFile],
        existingSizes: [String: Int64],
        importedSignatures: Set<String>,
        calendar: Calendar
    ) -> [ImportDecision] {
        var reserved = Set<String>()
        var seen = importedSignatures
        return files.map { file in
            let folder = monthDirectory(createdAt: file.createdAt, calendar: calendar)
            let name = fileName(file.name)
            let natural = "\(folder)/\(name)"
            if seen.contains(file.signature) {
                return ImportDecision(file: file, relativePath: natural, skip: true)
            }
            seen.insert(file.signature)
            if existingSizes[natural] == file.byteSize {
                return ImportDecision(file: file, relativePath: natural, skip: true)
            }
            let relative = allocate(folder: folder, fileName: name, existing: existingSizes, reserved: &reserved)
            return ImportDecision(file: file, relativePath: relative, skip: false)
        }
    }

    public static func downloadRequest(rootPath: String, relativePath: String) -> DeviceDownloadRequest {
        let url = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(relativePath)
        return DeviceDownloadRequest(
            directoryPath: url.deletingLastPathComponent().path,
            fileName: url.lastPathComponent,
            overwrite: false,
            deleteAfterDownload: false,
            includeSidecars: false
        )
    }

    public static func existingSizes(in root: URL) -> [String: Int64] {
        let rootPath = SourceCatalog.normalizedDirectory(root).path
        var sizes: [String: Int64] = [:]
        var pending = [rootPath]
        let fileManager = FileManager.default
        while let directory = pending.popLast() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    pending.append(path)
                    continue
                }
                guard let relative = FileCatalog.relativePath(file: path, root: rootPath) else { continue }
                let attributes = try? fileManager.attributesOfItem(atPath: path)
                sizes[relative] = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return sizes
    }

    private static func allocate(
        folder: String,
        fileName: String,
        existing: [String: Int64],
        reserved: inout Set<String>
    ) -> String {
        let url = URL(fileURLWithPath: fileName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 1
        while number < 1000 {
            let name: String
            if number == 1 {
                name = fileName
            } else if ext.isEmpty {
                name = "\(stem) \(number)"
            } else {
                name = "\(stem) \(number).\(ext)"
            }
            let relative = "\(folder)/\(name)"
            if existing[relative] == nil, !reserved.contains(relative) {
                reserved.insert(relative)
                return relative
            }
            number += 1
        }
        let fallback = "\(folder)/\(stem)-\(UUID().uuidString)"
        reserved.insert(fallback)
        return fallback
    }
}
