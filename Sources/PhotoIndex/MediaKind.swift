import Foundation

/// The kinds of media the library shows in the sidebar.
public enum MediaKind: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case photo
    case video
    case screenshot
    case screenRecording
}

public enum SourceKind: String, Codable, Sendable, Equatable, Hashable {
    case screenshots
    case photosLibrary
    case downloads
    case screenRecordings
    case folder
    /// A screenshot app's own save folder, such as CleanShot X or Shottr.
    case captureTool
}
