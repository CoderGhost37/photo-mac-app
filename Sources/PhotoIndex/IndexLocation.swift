import Foundation

/// The index lives on the Mac that built it. Nothing is uploaded or synced.
public enum IndexLocation {
    public static let folderName = "Stillroom"

    public static func directory(home: URL) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static func databaseURL(home: URL) -> URL {
        directory(home: home).appendingPathComponent("index.sqlite")
    }

    public static func thumbnailDirectory(home: URL) -> URL {
        directory(home: home).appendingPathComponent("Thumbnails", isDirectory: true)
    }

    public static func workDirectory(home: URL) -> URL {
        directory(home: home).appendingPathComponent("Work", isDirectory: true)
    }

    public static func scanDirectory(home: URL) -> URL {
        workDirectory(home: home).appendingPathComponent("Scans", isDirectory: true)
    }

    public static func temporaryExportDirectory(home: URL) -> URL {
        workDirectory(home: home).appendingPathComponent("Exports", isDirectory: true)
    }
}
