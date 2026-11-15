import AppKit
import Observation
import PhotoIndex
import UniformTypeIdentifiers
import SwiftUI

/// An optional companion to macOS's own screenshot capture and save flow.
@MainActor
@Observable
final class ScreenshotActionsController {
    struct Capture: Identifiable {
        let id = UUID()
        let url: URL
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            updateMonitoring()
        }
    }
    private(set) var captures: [Capture] = []
    private(set) var selectedID: UUID?
    private(set) var message: String?
    enum TextReadingState: Equatable {
        case idle
        case reading(token: UUID, captureID: UUID)
    }
    private(set) var textReadingState: TextReadingState = .idle
    var isReadingText: Bool { if case .reading = textReadingState { return true }; return false }
    @ObservationIgnored private var textTask: Task<Void, Never>?
    @ObservationIgnored private var scrollingWindow: ScrollingCaptureWindowController?
    @ObservationIgnored private var monitor: ScreenshotCaptureMonitor?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var panelDelegate: ScreenshotPanelDelegate?
    @ObservationIgnored private var editors: [URL: ScreenshotEditorWindowController] = [:]
    @ObservationIgnored private let onSaved: @MainActor (URL) -> Void
    private static let preferenceKey = "screenshotActionsEnabled"

    var selected: Capture? { captures.first { $0.id == selectedID } }

    init(onSaved: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.onSaved = onSaved
        isEnabled = !ScreenshotSession.isEnabled && UserDefaults.standard.bool(forKey: Self.preferenceKey)
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard isEnabled, !ScreenshotSession.isEnabled else {
            cancelTextReading()
            scrollingWindow?.cancel()
            monitor?.stop()
            monitor = nil
            panel?.orderOut(nil)
            return
        }
        guard monitor == nil else { return }
        let watcher = ScreenshotCaptureMonitor(
            onCapture: { [weak self] url in self?.receive(url) },
            onError: { [weak self] error in self?.report(error) }
        )
        monitor = watcher
        watcher.start()
    }

    private func receive(_ url: URL) {
        guard isEnabled, !ScreenshotSession.isEnabled else { return }
        guard !captures.contains(where: { $0.url == url }) else { return }
        let capture = Capture(url: url)
        captures.insert(capture, at: 0)
        // Keep a visible selection stable while the user is interacting with it.
        if selected == nil || panel?.isVisible != true {
            cancelTextReading()
            selectedID = capture.id
        }
        if captures.count > 20 {
            if let selectedID, let index = captures.firstIndex(where: { $0.id == selectedID }), index >= 20 {
                captures.remove(at: 19)
            } else {
                captures.removeLast()
            }
        }
        message = nil
        onSaved(url)
        showPanel(activate: false)
    }

    func select(_ capture: Capture) {
        cancelTextReading()
        selectedID = capture.id
        message = nil
        showPanel(activate: false)
    }

    func showRecent() {
        if selected == nil { selectedID = captures.first?.id }
        showPanel(activate: true)
    }

    func dismiss() {
        cancelTextReading()
        panel?.orderOut(nil)
    }

    func openScreenshot() {
        guard isEnabled else { return }
        let open = NSOpenPanel()
        open.title = "Open Screenshot"
        open.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.begin { [weak self] response in
            guard response == .OK, let url = open.url, let self, self.isEnabled else { return }
            if let existing = self.captures.first(where: { $0.url == url }) {
                self.select(existing)
            } else {
                self.dismiss()
                self.receive(url)
            }
            self.annotate()
        }
    }

    func scrollingCapture() {
        guard isEnabled, !ScreenshotSession.isEnabled else { return }
        dismiss()
        if scrollingWindow == nil {
            scrollingWindow = ScrollingCaptureWindowController { [weak self] output in
                guard let self, self.isEnabled else { return }
                self.monitor?.ignore(output)
                self.receive(output)
                if let capture = self.captures.first(where: { $0.url == output }) { self.select(capture) }
                self.annotate()
            }
        }
        scrollingWindow?.show()
    }

    private func cancelTextReading() {
        textTask?.cancel()
        textTask = nil
        textReadingState = .idle
    }

    func copyText() {
        guard isEnabled, let capture = selected, !isReadingText else { return }
        let token = UUID()
        textReadingState = .reading(token: token, captureID: capture.id)
        message = nil
        textTask = Task { [weak self] in
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try Self.recognizedText(at: capture.url)
                }.value
                guard let self, !Task.isCancelled, self.isEnabled, self.selectedID == capture.id,
                      self.textReadingState == .reading(token: token, captureID: capture.id) else { return }
                self.textReadingState = .idle
                self.textTask = nil
                guard !text.isEmpty else {
                    self.message = "No readable text was found. The clipboard has not changed."
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.setString(text, forType: .string) {
                    self.message = "Text copied. Recognition stays on this Mac."
                } else {
                    self.report("The recognized text could not be copied to the clipboard.")
                }
            } catch {
                guard let self, !Task.isCancelled, self.isEnabled, self.selectedID == capture.id,
                      self.textReadingState == .reading(token: token, captureID: capture.id) else { return }
                self.textReadingState = .idle
                self.textTask = nil
                self.report("Could not read text. \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func recognizedText(at url: URL) throws -> String {
        let observations = try VisionTextReader.recognize(file: url).sorted {
            if $0.box.y + $0.box.height == $1.box.y + $1.box.height { return $0.box.x < $1.box.x }
            return $0.box.y + $0.box.height > $1.box.y + $1.box.height
        }
        var rows: [[TextObservation]] = []
        for observation in observations {
            if let index = rows.firstIndex(where: { row in
                guard let first = row.first else { return false }
                return abs((first.box.y + first.box.height / 2) - (observation.box.y + observation.box.height / 2))
                    <= min(first.box.height, observation.box.height) / 2
            }) {
                rows[index].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.map { $0.sorted { $0.box.x < $1.box.x }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    func takeScreenshot() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            report("macOS Screenshot could not be found. You can still use Shift–Command–3 or Shift–Command–4.")
            return
        }
        dismiss()
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.report("Could not open macOS Screenshot: \(error.localizedDescription)") }
            }
        }
    }

    func copy() {
        cancelTextReading()
        guard let capture = selected, let image = NSImage(contentsOf: capture.url) else {
            report("This screenshot could not be read. It may have been moved or deleted.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            message = "Image copied. The saved screenshot stays where it is."
        } else {
            report("The screenshot could not be copied to the clipboard.")
        }
    }

    func annotate() {
        guard let capture = selected else { return }
        guard FileManager.default.fileExists(atPath: capture.url.path) else {
            report("This screenshot has been moved or deleted.")
            return
        }
        let editor: ScreenshotEditorWindowController
        if let existing = editors[capture.url] {
            editor = existing
        } else {
            editor = ScreenshotEditorWindowController(url: capture.url) { [weak self] output in
                self?.monitor?.ignore(output)
                self?.onSaved(output)
            }
            editors[capture.url] = editor
        }
        // Closed editors can be released; open editors and their edits remain intact.
        editors = editors.filter { $0.key == capture.url || $0.value.window?.isVisible == true || $0.value.window?.isMiniaturized == true }
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func saveCopy() {
        guard let capture = selected else { return }
        let save = NSSavePanel()
        save.title = "Save a Copy"
        save.message = "The original screenshot is already saved by macOS. Choose a new name for this copy."
        save.nameFieldStringValue = capture.url.deletingPathExtension().lastPathComponent + " copy." + capture.url.pathExtension
        save.directoryURL = capture.url.deletingLastPathComponent()
        save.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        save.begin { [weak self] response in
            guard response == .OK, let output = save.url, let self else { return }
            do {
                // copyItem refuses to replace an existing file, even after the save panel's confirmation.
                self.monitor?.ignore(output)
                try FileManager.default.copyItem(at: capture.url, to: output)
                self.message = "Copy saved as \(output.lastPathComponent)."
                self.onSaved(output)
            } catch {
                self.report("Could not save the copy: \(error.localizedDescription) Choose a new filename; existing files are never replaced.")
            }
        }
    }

    private func report(_ error: String) {
        message = error
        if isEnabled { showPanel(activate: false) }
    }

    private func showPanel(activate: Bool) {
        guard isEnabled, !ScreenshotSession.isEnabled else { return }
        if panel == nil {
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            window.title = "Screenshot Actions"
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            let delegate = ScreenshotPanelDelegate { [weak self] in self?.cancelTextReading() }
            panelDelegate = delegate
            window.delegate = delegate
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: ScreenshotActionsView(controller: self))
            if let frame = NSScreen.main?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 404, y: frame.minY + 420))
            }
            panel = window
        }
        panel?.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKey()
        }
    }
}

@MainActor
private final class ScreenshotPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct ScreenshotActionsView: View {
    @Bindable var controller: ScreenshotActionsController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(controller.selected == nil ? "Screenshot Actions" : "Screenshot saved", systemImage: controller.selected == nil ? "camera.viewfinder" : "checkmark.circle")
                    .font(.headline)
                Spacer()
                Button { controller.dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss screenshot actions")
                .help("Dismiss without deleting the screenshot")
            }
            if let capture = controller.selected {
                if let image = NSImage(contentsOf: capture.url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.raisedColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onDrag { NSItemProvider(object: capture.url as NSURL) }
                        .accessibilityLabel("Screenshot preview. Drag to share the saved file.")
                        .help("Drag the saved screenshot into another app")
                }
                Text(capture.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { controller.copy() }
                    Button { controller.copyText() } label: {
                        if controller.isReadingText { ProgressView().controlSize(.mini) }
                        Text(controller.isReadingText ? "Reading…" : "Copy Text")
                    }
                    .disabled(controller.isReadingText)
                    .help("Recognize text on this Mac and copy it to the clipboard")
                }
                .controlSize(.small)
                HStack {
                    Button("Annotate", systemImage: "pencil.tip.crop.circle") { controller.annotate() }
                    Button("Save a Copy…") { controller.saveCopy() }
                }
                .controlSize(.small)
            } else {
                Text("New screenshots saved by macOS will appear here. Use your usual screenshot shortcuts or Take Screenshot below.")
                    .foregroundStyle(Palette.secondaryColor)
                    .frame(maxHeight: .infinity)
            }
            if let message = controller.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
            HStack {
                Menu("Recent (\(controller.captures.count))") {
                    ForEach(controller.captures) { capture in
                        Button(capture.url.lastPathComponent) { controller.select(capture) }
                    }
                }
                .disabled(controller.captures.isEmpty)
                Spacer()
                Menu("Capture") {
                    Button("Take Screenshot…") { controller.takeScreenshot() }
                    Button("Scrolling Capture…") { controller.scrollingCapture() }
                    Button("Open Screenshot…") { controller.openScreenshot() }
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 380, height: 380)
        .foregroundStyle(Palette.inkColor)
        .background(Palette.canvasColor)
        .tint(Palette.accentColor)
    }
}
