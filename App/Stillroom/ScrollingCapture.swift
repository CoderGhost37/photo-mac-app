import AppKit
import CoreGraphics
import PhotoIndex
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScrollingCaptureWindowController: NSWindowController, NSWindowDelegate {
    private let model = ScrollingCaptureModel()
    private var worker = ScrollingCaptureWorker()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var regionSelector: CaptureRegionSelector?
    private let onSaved: @MainActor (URL) -> Void

    init(onSaved: @escaping @MainActor (URL) -> Void) {
        self.onSaved = onSaved
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Scrolling Capture"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ScrollingCaptureView(model: model,
            selectRegion: { [weak self] in self?.selectRegion() },
            capture: { [weak self] in self?.captureNext() },
            importFrames: { [weak self] in self?.importFrames() },
            finish: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.cancel() }))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { cancel() }

    func prepareToQuit() async {
        let previous = worker
        cancel()
        await previous.cancel()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        regionSelector?.cancel()
        regionSelector = nil
        let previous = worker
        worker = ScrollingCaptureWorker()
        Task { await previous.cancel() }
        model.reset()
        window?.orderOut(nil)
    }

    private func selectRegion() {
        guard !model.isBusy, model.frameCount == 0 else { return }
        window?.orderOut(nil)
        let selector = CaptureRegionSelector { [weak self] region in
            guard let self else { return }
            self.regionSelector = nil
            if let region { self.model.region = region }
            self.model.message = region == nil ? "Region selection canceled." : "Region selected. Capture the first frame, then scroll down manually."
            self.show()
        }
        regionSelector = selector
        selector.show()
    }

    private func captureNext() {
        guard !model.isBusy, let region = model.region else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            model.message = "Screen Recording access is required. Allow Stillroom in System Settings, then relaunch it if macOS asks. Your accepted frames are still available."
            return
        }
        let session = generation, worker = worker
        model.isBusy = true
        model.message = "Capturing the selected region…"
        window?.orderOut(nil)
        task = Task { [weak self] in
            do {
                // Let the window server remove these controls before taking a frame.
                try await Task.sleep(for: .milliseconds(250))
                let progress = try await worker.capture(region: region)
                guard let self, self.generation == session, !Task.isCancelled else { return }
                self.model.accept(progress)
                self.model.message = "Frame accepted. Scroll down manually, keeping at least 25% overlap, then capture again."
                self.show()
            } catch {
                guard let self, self.generation == session, !Task.isCancelled else { return }
                self.model.isBusy = false
                self.model.message = error.localizedDescription + " Accepted frames are still available."
                self.show()
            }
        }
    }

    private func importFrames() {
        guard !model.isBusy else { return }
        let open = NSOpenPanel()
        open.title = "Import Overlapping Frames"
        open.message = "Frames are added in filename order. Use equal-sized images with at least 25% vertical overlap."
        open.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = open.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let session = self.generation, worker = self.worker
            self.model.isBusy = true
            self.model.message = "Checking imported frames…"
            self.task = Task { [weak self] in
                let progress = await worker.importFrames(urls)
                guard let self, self.generation == session, !Task.isCancelled else { return }
                self.model.accept(progress)
                self.model.message = progress.error ?? "Frames accepted. Add more frames or finish and save."
            }
        }
    }

    private func finish() {
        guard !model.isBusy, model.frameCount >= 2, let window else { return }
        let save = NSSavePanel()
        save.title = "Save Scrolling Capture"
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "Scrolling Capture.png"
        save.canCreateDirectories = true
        save.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        save.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let output = save.url, let self else { return }
            let session = self.generation, worker = self.worker
            self.model.isBusy = true
            self.model.message = "Stitching and saving…"
            self.task = Task { [weak self] in
                do {
                    let saved = try await worker.finish(to: output)
                    guard let self, self.generation == session, !Task.isCancelled else { return }
                    self.cancel()
                    self.onSaved(saved)
                } catch {
                    guard let self, self.generation == session, !Task.isCancelled else { return }
                    self.model.isBusy = false
                    self.model.message = "Could not save. " + error.localizedDescription + " Accepted frames are still available."
                }
            }
        }
    }
}

@MainActor
private final class ScrollingCaptureModel: ObservableObject {
    @Published var region: CGRect?
    @Published var frameCount = 0
    @Published var height = 0
    @Published var isBusy = false
    @Published var message: String?

    func accept(_ progress: ScrollingCaptureProgress) {
        frameCount = progress.count
        height = progress.height
        isBusy = false
    }

    func reset() {
        region = nil
        frameCount = 0
        height = 0
        isBusy = false
        message = nil
    }
}

private struct ScrollingCaptureView: View {
    @ObservedObject var model: ScrollingCaptureModel
    let selectRegion: () -> Void
    let capture: () -> Void
    let importFrames: () -> Void
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build a scrolling screenshot").font(.title2.bold())
            Text("Select the content region on one display. Capture a frame, scroll down manually, and capture the next frame. Keep at least 25% of the previous frame visible. Exclude fixed headers, scroll bars, and moving content.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Stillroom does not scroll other apps for you. Frames stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.region == nil ? "Select Region…" : "Change Region…", action: selectRegion)
                    .disabled(model.isBusy || model.frameCount > 0)
                Button(model.frameCount == 0 ? "Capture First Frame" : "Capture Next Frame", action: capture)
                    .disabled(model.isBusy || model.region == nil)
            }
            HStack {
                Text("\(model.frameCount) accepted frames · \(model.height) px tall")
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            .font(.callout)
            Text(model.message ?? "You can also import equal-sized frames in filename order. Capture stops at 30,000 pixels tall or the memory limit.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .accessibilityLabel(model.message ?? "Ready to capture")
            Spacer(minLength: 0)
            HStack {
                Button("Import Frames…", action: importFrames).disabled(model.isBusy)
                Spacer()
                Button("Cancel", action: cancel)
                Button("Finish & Save…", action: finish)
                    .disabled(model.isBusy || model.frameCount < 2)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 380)
    }
}

private struct ScrollingCaptureProgress: Sendable {
    let count: Int
    let height: Int
    var error: String?
}

private actor ScrollingCaptureWorker {
    private var session = ScreenshotStitching.Session()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Stillroom-Scrolling-\(UUID().uuidString)", isDirectory: true)
    private var process: Process?
    private var canceled = false

    func capture(region: CGRect) async throws -> ScrollingCaptureProgress {
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let rect = [region.minX, region.minY, region.width, region.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        process.arguments = ["-x", "-R" + rect, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completed in continuation.resume(returning: completed.terminationStatus) }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        self.process = nil
        guard !canceled else { throw CancellationError() }
        guard status == 0, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw CaptureFailure.failed
        }
        do {
            try session.append(output)
            return progress()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    func importFrames(_ urls: [URL]) -> ScrollingCaptureProgress {
        for url in urls {
            if canceled || Task.isCancelled { return progress(error: "Import canceled.") }
            let output = directory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: output)
                try session.append(output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                return progress(error: "Stopped at \(url.lastPathComponent). " + error.localizedDescription + " Accepted frames are still available.")
            }
        }
        return progress()
    }

    func finish(to output: URL) throws -> URL {
        try Task.checkCancellation()
        guard !canceled, let original = session.frames.first?.url else { throw CancellationError() }
        let image = try session.render()
        try Task.checkCancellation()
        return try ScreenshotEditing.saveCopy(image, suggestedURL: output, originalURL: original)
    }

    func cancel() {
        canceled = true
        if process?.isRunning == true { process?.terminate() }
        session = ScreenshotStitching.Session()
        try? FileManager.default.removeItem(at: directory)
    }

    private func progress(error: String? = nil) -> ScrollingCaptureProgress {
        ScrollingCaptureProgress(count: session.frames.count, height: session.height, error: error)
    }

    private enum CaptureFailure: LocalizedError {
        case failed
        var errorDescription: String? { "The region could not be captured. Allow Screen Recording for Stillroom in System Settings and keep the selected display connected." }
    }
}

@MainActor
private final class CaptureRegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?

    init(completion: @escaping (CGRect?) -> Void) { self.completion = completion }

    func show() {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let window = RegionSelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size)) { [weak self] rect in
                guard let rect else { self?.complete(nil); return }
                let quartzRect = CGRect(x: displayBounds.minX + rect.minX,
                                        y: displayBounds.minY + screen.frame.height - rect.maxY,
                                        width: rect.width, height: rect.height).integral
                self?.complete(quartzRect)
            }
            window.contentView = view
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        completion = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func complete(_ rect: CGRect?) {
        let callback = completion
        cancel()
        callback?(rect)
    }
}

private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    private var start: CGPoint?
    private var selection: CGRect?
    private let completion: (CGRect?) -> Void
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let selection {
            NSColor.white.withAlphaComponent(0.25).setFill()
            selection.fill()
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
        }
        let instruction = "Drag to select a region on this display. Press Escape to cancel."
        instruction.draw(at: CGPoint(x: 30, y: bounds.height - 60), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
    }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let selection, selection.width >= 16, selection.height >= 16 else { return }
        completion(selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) } else { super.keyDown(with: event) }
    }
}
