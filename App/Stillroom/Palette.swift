import AppKit
import PhotoIndex
import SwiftUI

enum Palette {
    /// Violet accent. Light #6A45F5, dark #7B5CFF. The asset catalog is the SwiftUI accent.
    static let accent = dynamic(
        light: NSColor(srgbRed: 106.0 / 255.0, green: 69.0 / 255.0, blue: 245.0 / 255.0, alpha: 1),
        dark: NSColor(srgbRed: 123.0 / 255.0, green: 92.0 / 255.0, blue: 1, alpha: 1)
    )
    static let secondaryBlue = NSColor(srgbRed: 143.0 / 255.0, green: 179.0 / 255.0, blue: 1, alpha: 1)
    /// Pink used for favorites and memories. Not for chrome or body text.
    static let favorite = NSColor(srgbRed: 240.0 / 255.0, green: 111.0 / 255.0, blue: 181.0 / 255.0, alpha: 1)
    static let navy = NSColor(srgbRed: 10.0 / 255.0, green: 11.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
    static let sidebar = NSColor.windowBackgroundColor
    static let canvas = NSColor.windowBackgroundColor
    static let inspector = NSColor.controlBackgroundColor
    static let ink = NSColor.labelColor
    static let cell = NSColor.quaternaryLabelColor

    static var sidebarColor: Color { Color(nsColor: sidebar) }
    static var canvasColor: Color { Color(nsColor: canvas) }
    static var inspectorColor: Color { Color(nsColor: inspector) }
    static var inkColor: Color { Color(nsColor: ink) }
    static var accentColor: Color { Color.accentColor }
    static var favoriteColor: Color { Color(nsColor: favorite) }
    static var secondaryBlueColor: Color { Color(nsColor: secondaryBlue) }
    /// At most a 4% navy wash over the system window background.
    static var navyTint: Color { Color(nsColor: navy).opacity(0.04) }
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 123.0 / 255.0, green: 92.0 / 255.0, blue: 1),
                Color(nsColor: secondaryBlue),
                Color(nsColor: favorite)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

enum Format {
    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func coordinate(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    static func aperture(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "ƒ/%.1f", value)
    }

    static func shutter(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 1 {
            return String(format: "%.1f s", seconds)
        }
        let denominator = max(1, Int((1.0 / seconds).rounded()))
        return "1/\(denominator) s"
    }

    static func focalLength(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "%.0f mm", value)
    }

    static func mediaTitle(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "Photos"
        case .video: return "Videos"
        case .screenshot: return "Screenshots"
        case .screenRecording: return "Screen Recordings"
        }
    }

    static func mediaSymbol(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "photo"
        case .video: return "video"
        case .screenshot: return "camera.viewfinder"
        case .screenRecording: return "record.circle"
        }
    }

    static func sourceSymbol(_ kind: SourceKind) -> String {
        switch kind {
        case .screenshots: return "camera.viewfinder"
        case .photosLibrary: return "photo.on.rectangle.angled"
        case .downloads: return "arrow.down.circle"
        case .screenRecordings: return "record.circle"
        case .folder: return "folder"
        case .captureTool: return "camera.viewfinder"
        }
    }

    static func dayTitle(for date: Date?) -> String {
        guard let date else { return "No date" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    static func dayKey(for date: Date?) -> String {
        guard let date else { return "none" }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
