import Foundation

public enum HiddenLock {
    /// The Hidden album locks again this long after the last activity in it.
    public static let timeout: TimeInterval = 60

    /// Stays unlocked while Touch ID or the password dialog is up, so that dialog does not lock the album.
    public static func shouldLock(
        inactive: Bool,
        authenticating: Bool,
        lastActivity: Date?,
        now: Date,
        timeout: TimeInterval = HiddenLock.timeout
    ) -> Bool {
        if authenticating { return false }
        if inactive { return true }
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= timeout
    }
}
