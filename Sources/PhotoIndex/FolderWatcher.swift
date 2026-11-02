import Foundation

#if canImport(CoreServices)
import CoreServices

/// Watches folder sources with FSEvents and reports changed paths.
/// The app debounces these and runs an incremental scan. QoS is utility.
public final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Stillroom.FolderWatcher", qos: .utility)
    private let onChange: @Sendable (String) -> Void
    private var stream: FSEventStreamRef?

    public init(onChange: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// `paths` are watched until `stop`. The owner must keep this object alive.
    public func start(paths: [String]) {
        stop()
        let paths = Array(Set(paths)).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            folderWatcherCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        self.stream = nil
        queue.sync { }
        FSEventStreamRelease(stream)
    }

    fileprivate func handle(path: String) {
        onChange(path)
    }
}

private let folderWatcherCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self)
    for case let path as String in paths {
        watcher.handle(path: path)
    }
}
#endif
