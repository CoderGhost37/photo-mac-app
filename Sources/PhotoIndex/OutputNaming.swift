import Foundation

public enum OutputPlace: Equatable, Sendable {
    /// Same folder as the source file.
    case besideSource
    /// A folder the user picked.
    case folder(String)
}

public enum OutputNameError: Error, Equatable, LocalizedError {
    case needsFolder
    case missingDirectory
    case noFreeName
    case destinationOccupied(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .needsFolder:
            return "This item is not a file on disk. Choose a folder for the new file."
        case .missingDirectory:
            return "The destination folder is missing."
        case .noFreeName:
            return "Could not find a free file name. Nothing was written."
        case .destinationOccupied(let name):
            return "\(name) already exists, so nothing was written."
        case .writeFailed(let name):
            return "Could not write \(name)."
        }
    }
}

public enum OutputNamer {
    /// Comparison key for reserved names and the original path.
    /// `exists` is still called with the real candidate path. On a case-insensitive disk, that check should be case-insensitive too. FileManager is, on macOS.
    public static func comparisonKey(_ path: String, caseInsensitive: Bool) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return caseInsensitive ? standard.lowercased() : standard
    }

    public static func stem(of displayName: String) -> String {
        let base = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Converted" : trimmed
    }

    /// Picks `stem.ext`, then `stem 2.ext`, and so on. Never returns `sourcePath` or a reserved path.
    public static func allocate(
        displayName: String,
        sourcePath: String?,
        fileExtension: String,
        directory: String,
        reserved: inout Set<String>,
        exists: (String) -> Bool,
        caseInsensitive: Bool = true,
        forbiddenPaths: [String] = [],
        limit: Int = 999
    ) -> Result<String, OutputNameError> {
        let directoryURL = URL(fileURLWithPath: directory).standardizedFileURL
        let dir = directoryURL.path
        if dir.isEmpty || dir == "." || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.missingDirectory)
        }
        let stem = stem(of: displayName)
        let ext = fileExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return .failure(.noFreeName) }
        var forbidden = Set(forbiddenPaths.map { comparisonKey($0, caseInsensitive: caseInsensitive) })
        if let sourcePath {
            forbidden.insert(comparisonKey(sourcePath, caseInsensitive: caseInsensitive))
        }
        var number = 1
        while number <= limit {
            let name = number == 1 ? "\(stem).\(ext)" : "\(stem) \(number).\(ext)"
            let path = directoryURL.appendingPathComponent(name).path
            let key = comparisonKey(path, caseInsensitive: caseInsensitive)
            let taken = reserved.contains(key) || forbidden.contains(key) || exists(path)
            if !taken {
                reserved.insert(key)
                return .success(path)
            }
            number += 1
        }
        return .failure(.noFreeName)
    }

    /// Writes `body` to a new temporary file, then moves it to `destination` only if that path is still free.
    /// The temporary file is removed if the move does not happen. `destination` is never replaced.
    public static func writeAtomically(to destination: URL, body: (URL) throws -> Void) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).stillroom-part")
        defer { try? FileManager.default.removeItem(at: partial) }
        try body(partial)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw OutputNameError.destinationOccupied(destination.lastPathComponent)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw OutputNameError.writeFailed(destination.lastPathComponent)
        }
    }

    /// Async form of `writeAtomically`. The destination is still never replaced.
    public static func writeAtomically(to destination: URL, body: (URL) async throws -> Void) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).stillroom-part")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await body(partial)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw OutputNameError.destinationOccupied(destination.lastPathComponent)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw OutputNameError.writeFailed(destination.lastPathComponent)
        }
    }
}

public struct ConvertPlanInput: Equatable, Sendable {
    public var displayName: String
    public var sourcePath: String?
    public var fileExtension: String

    public init(displayName: String, sourcePath: String?, fileExtension: String) {
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.fileExtension = fileExtension
    }
}

public struct PlannedConversion: Equatable, Sendable {
    public var displayName: String
    public var sourcePath: String?
    public var outputPath: String?
    public var skipReason: String?

    public init(displayName: String, sourcePath: String?, outputPath: String?, skipReason: String?) {
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.skipReason = skipReason
    }
}

public enum ConvertPlanner {
    public static func plan(
        inputs: [ConvertPlanInput],
        format: ConvertFormat,
        place: OutputPlace,
        encode: EncodeAvailability,
        exists: (String) -> Bool,
        caseInsensitive: Bool = true
    ) -> [PlannedConversion] {
        var reserved = Set<String>()
        return inputs.map { input in
            planOne(
                input,
                format: format,
                place: place,
                encode: encode,
                reserved: &reserved,
                exists: exists,
                caseInsensitive: caseInsensitive
            )
        }
    }

    private static func planOne(
        _ input: ConvertPlanInput,
        format: ConvertFormat,
        place: OutputPlace,
        encode: EncodeAvailability,
        reserved: inout Set<String>,
        exists: (String) -> Bool,
        caseInsensitive: Bool
    ) -> PlannedConversion {
        if encode.format == format && !encode.available {
            return PlannedConversion(
                displayName: input.displayName,
                sourcePath: input.sourcePath,
                outputPath: nil,
                skipReason: encode.unavailableReason ?? "\(format.title) cannot be written on this Mac."
            )
        }
        if let reason = ConvertRouting.rejection(
            fileName: input.displayName,
            fileExtension: input.fileExtension,
            format: format
        ) {
            return PlannedConversion(
                displayName: input.displayName,
                sourcePath: input.sourcePath,
                outputPath: nil,
                skipReason: reason
            )
        }
        let directory: String
        switch place {
        case .besideSource:
            guard let sourcePath = input.sourcePath else {
                return PlannedConversion(
                    displayName: input.displayName,
                    sourcePath: nil,
                    outputPath: nil,
                    skipReason: OutputNameError.needsFolder.errorDescription
                )
            }
            directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
        case .folder(let folder):
            directory = folder
        }
        let allocated = OutputNamer.allocate(
            displayName: input.displayName,
            sourcePath: input.sourcePath,
            fileExtension: format.fileExtension,
            directory: directory,
            reserved: &reserved,
            exists: exists,
            caseInsensitive: caseInsensitive,
            forbiddenPaths: input.sourcePath.map { [$0] } ?? []
        )
        switch allocated {
        case .success(let path):
            return PlannedConversion(
                displayName: input.displayName,
                sourcePath: input.sourcePath,
                outputPath: path,
                skipReason: nil
            )
        case .failure(let error):
            return PlannedConversion(
                displayName: input.displayName,
                sourcePath: input.sourcePath,
                outputPath: nil,
                skipReason: error.errorDescription
            )
        }
    }
}
