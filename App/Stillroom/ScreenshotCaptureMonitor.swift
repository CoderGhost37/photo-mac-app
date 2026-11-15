import Foundation
import ImageIO
import PhotoIndex
import Darwin

/// Observes native screenshot files without changing the system screenshot configuration.
@MainActor
final class ScreenshotCaptureMonitor {
    private let onCapture: @MainActor (URL) -> Void
    private let onError: @MainActor (String) -> Void
    private var worker: ScreenshotCaptureWorker?
    private var locationTask: Task<Void, Never>?
    private var generation = UUID()
    private var ignoredPaths: Set<String> = []

    init(onCapture: @escaping @MainActor (URL) -> Void,
         onError: @escaping @MainActor (String) -> Void) {
        self.onCapture = onCapture
        self.onError = onError
    }

    func start() {
        guard worker == nil else { return }
        generation = UUID()
        let session = generation
        let worker = ScreenshotCaptureWorker(ignoredPaths: ignoredPaths, onCapture: { [weak self] url in
            guard let self, self.generation == session,
                  !self.ignoredPaths.contains(url.standardizedFileURL.path) else { return }
            self.onCapture(url)
        }, onError: { [weak self] message in
            guard let self, self.generation == session else { return }
            self.onError(message)
        })
        self.worker = worker
        locationTask = Task {
            await worker.refreshLocation()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
                await worker.refreshLocation()
            }
            await worker.stop()
        }
    }

    func stop() {
        generation = UUID()
        locationTask?.cancel()
        locationTask = nil
        let previous = worker
        worker = nil
        Task { await previous?.stop() }
    }

    /// Call before writing an editor export so it cannot reopen the capture panel.
    func ignore(_ url: URL) {
        let path = url.standardizedFileURL.path
        ignoredPaths.insert(path)
        let worker = worker
        Task { await worker?.ignore(path) }
    }

    deinit {
        locationTask?.cancel()
        let worker = worker
        Task { await worker?.stop() }
    }
}

private actor ScreenshotCaptureWorker {
    private let onCapture: @MainActor @Sendable (URL) -> Void
    private let onError: @MainActor @Sendable (String) -> Void
    private var folder: URL?
    private var watcher: FolderWatcher?
    private var detector = ScreenshotDetection(startedAt: Date())
    private var ignoredPaths: Set<String>
    private var pending: [String: Task<Void, Never>] = [:]
    private var stopped = false
    private var lastError: String?

    init(ignoredPaths: Set<String>,
         onCapture: @escaping @MainActor @Sendable (URL) -> Void,
         onError: @escaping @MainActor @Sendable (String) -> Void) {
        self.ignoredPaths = ignoredPaths
        self.onCapture = onCapture
        self.onError = onError
    }

    func refreshLocation() async {
        guard !stopped else { return }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        let current = ScreenshotLocation.current().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: current.path) else {
            clearWatch()
            await report("The screenshot folder is unavailable: \(current.path)")
            return
        }
        guard current != folder else { return }
        clearWatch()
        do {
            let existing = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            detector = ScreenshotDetection(startedAt: Date(), existingPaths: Set(existing.map { $0.standardizedFileURL.path }))
            for path in ignoredPaths { detector.ignore(path: path) }
            folder = current
            let watcher = FolderWatcher { [weak self] path in
                Task { await self?.changed(path) }
            }
            self.watcher = watcher
            watcher.start(paths: [current.path])
            lastError = nil
        } catch {
            await report("Stillroom couldn’t read the screenshot folder: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopped = true
        clearWatch()
    }

    func ignore(_ path: String) {
        ignoredPaths.insert(path)
        detector.ignore(path: path)
        pending.removeValue(forKey: path)?.cancel()
    }

    private func clearWatch() {
        watcher?.stop()
        watcher = nil
        folder = nil
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func report(_ message: String) async {
        guard lastError != message, !stopped else { return }
        lastError = message
        await onError(message)
    }

    private func changed(_ path: String) {
        guard !stopped, let folder else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == folder else { return }
        guard pending[path] == nil, !ignoredPaths.contains(path),
              !url.lastPathComponent.hasPrefix(".") else { return }
        pending[path] = Task { [weak self] in
            for _ in 0..<16 {
                guard !Task.isCancelled else { break }
                guard let self else { return }
                let finished = await self.inspect(url)
                if finished { break }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
            }
            await self?.finished(path)
        }
    }

    private func finished(_ path: String) {
        pending.removeValue(forKey: path)
    }

    private func inspect(_ url: URL) async -> Bool {
        guard !stopped, !Task.isCancelled,
              url.deletingLastPathComponent() == folder else { return true }
        let decision = detector.observe(path: url.path, observation: Self.observation(url))
        switch decision {
        case .retry:
            return false
        case .ignore:
            return true
        case .capture:
            guard !Task.isCancelled, !stopped else { return true }
            await onCapture(url)
            return true
        }
    }

    private static func observation(_ url: URL) -> ScreenshotDetection.Observation? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let created = attributes[.creationDate] as? Date,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        let native = isNativeScreenshot(url)
        let readable: Bool
        if native, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0,
           CGImageSourceGetStatus(source) == .statusComplete {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true
            ]
            readable = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
        } else {
            readable = false
        }
        return .init(creationDate: created, modificationDate: modified, byteCount: size.int64Value,
                     isNativeScreenshot: native, isReadableImage: readable)
    }

    private static func isNativeScreenshot(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        guard count > 0, count < 4096 else { return false }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, count, 0, 0)
        }
        guard read == count,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }
}
