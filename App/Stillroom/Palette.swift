import AppKit
import PhotoIndex
import SwiftUI

enum Palette {
    static var canvasColor: Color { Color("Canvas") }
    static var sidebarColor: Color { Color("Sidebar") }
    static var raisedColor: Color { Color("Raised") }
    static var inkColor: Color { Color("Ink") }
    static var secondaryColor: Color { Color("SecondaryInk") }
    static var borderColor: Color { Color("Border") }
    static var accentColor: Color { Color.accentColor }

    static var canvasNSColor: NSColor { named("Canvas") }
    static var inkNSColor: NSColor { named("Ink") }

    /// Simplified stand-in for the mesh-gradient app mark.
    static var markGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 123.0 / 255.0, green: 92.0 / 255.0, blue: 1),
                Color(red: 214.0 / 255.0, green: 98.0 / 255.0, blue: 176.0 / 255.0),
                Color(red: 242.0 / 255.0, green: 140.0 / 255.0, blue: 92.0 / 255.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func named(_ name: String) -> NSColor {
        NSColor(named: name) ?? .labelColor
    }
}

enum StillroomFont {
    /// System text at 20pt and above uses SF Pro Display.
    static let title = Font.system(size: 22, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let control = Font.system(size: 13)
    static let controlMedium = Font.system(size: 13, weight: .medium)
    static let metadata = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let path = Font.system(size: 11, design: .monospaced)
}

struct AppMark: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Palette.markGradient)
            .frame(width: size, height: size)
            .overlay {
                Text("S")
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Stillroom")
    }
}

enum Metrics {
    static let gridSpacing: CGFloat = 6
    static let pageInset: CGFloat = 20
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

    static func megapixels(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let value = Double(width * height) / 1_000_000
        guard value >= 0.1 else { return nil }
        if value >= 10 {
            return String(format: "%.0f MP", value.rounded())
        }
        return String(format: "%.1f MP", value)
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

    static func viewerStamp(_ date: Date?) -> String {
        guard let date else { return "" }
        return viewerFormatter.string(from: date)
    }

    static func longDay(_ date: Date) -> String {
        longDayFormatter.string(from: date)
    }

    static func monthYear(_ date: Date) -> String {
        monthYearFormatter.string(from: date)
    }

    static func shortMonthDay(_ date: Date) -> String {
        shortMonthDayFormatter.string(from: date)
    }

    static func year(_ date: Date) -> String {
        String(Calendar.current.component(.year, from: date))
    }

    static func coordinate(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    static func aperture(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 10 {
            return String(format: "ƒ/%.0f", value)
        }
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
        case .screenshot: return "rectangle.dashed"
        case .screenRecording: return "record.circle"
        }
    }

    static func sourceSymbol(_ kind: SourceKind) -> String {
        switch kind {
        case .screenshots: return "rectangle.dashed"
        case .photosLibrary: return "photo.on.rectangle.angled"
        case .downloads: return "arrow.down.circle"
        case .screenRecordings: return "record.circle"
        case .folder: return "folder"
        case .captureTool: return "camera.viewfinder"
        }
    }

    static func fileExtension(_ asset: Asset) -> String? {
        guard let path = asset.filePath else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    static func fileName(_ asset: Asset) -> String {
        if let path = asset.filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return Format.mediaTitle(asset.mediaKind)
    }

    static func folderName(_ asset: Asset) -> String? {
        guard let path = asset.filePath else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    static func countPhrase(_ value: Int, singular: String, plural: String) -> String {
        "\(count(value)) \(value == 1 ? singular : plural)"
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

    private static let viewerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy · h:mm a"
        return formatter
    }()

    private static let longDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let shortMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
