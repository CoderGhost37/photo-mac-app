import AppKit
import PhotoIndex
import SwiftUI

enum Palette {
    static let sidebar = dynamic(
        light: NSColor(srgbRed: 0.955, green: 0.941, blue: 0.910, alpha: 1),
        dark: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.133, alpha: 1)
    )
    static let canvas = dynamic(
        light: NSColor(srgbRed: 0.910, green: 0.894, blue: 0.855, alpha: 1),
        dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.105, alpha: 1)
    )
    static let inspector = dynamic(
        light: NSColor(srgbRed: 0.973, green: 0.965, blue: 0.945, alpha: 1),
        dark: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.155, alpha: 1)
    )
    static let ink = dynamic(
        light: NSColor(srgbRed: 0.165, green: 0.153, blue: 0.125, alpha: 1),
        dark: NSColor(srgbRed: 0.93, green: 0.91, blue: 0.86, alpha: 1)
    )
    static let accent = NSColor(srgbRed: 0.122, green: 0.420, blue: 0.290, alpha: 1)
    static let cell = dynamic(
        light: NSColor(srgbRed: 0.84, green: 0.82, blue: 0.76, alpha: 1),
        dark: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.20, alpha: 1)
    )

    static var sidebarColor: Color { Color(nsColor: sidebar) }
    static var canvasColor: Color { Color(nsColor: canvas) }
    static var inspectorColor: Color { Color(nsColor: inspector) }
    static var inkColor: Color { Color(nsColor: ink) }
    static var accentColor: Color { Color(nsColor: accent) }

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
        case .video: return "film"
        case .screenshot: return "rectangle.dashed"
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
