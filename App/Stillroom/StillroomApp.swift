import SwiftUI

@main
struct StillroomApp: App {
    @NSApplicationDelegateAdaptor(StillroomApplicationDelegate.self) private var applicationDelegate
    @State private var model: AppModel
    @State private var screenshotActions: ScreenshotActionsController

    init() {
        let appModel = AppModel()
        _model = State(initialValue: appModel)
        _screenshotActions = State(initialValue: ScreenshotActionsController { url in
            appModel.screenshotSaved(url)
        })
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    if ScreenshotSession.isEnabled {
                        await ScreenshotSession.run(model: model)
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder…") {
                    model.addFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Import from iPhone…") {
                    model.openImport()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Convert…") {
                    model.openConvert()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("PDF…") {
                    model.openPDF()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                Toggle("Screenshot Actions", isOn: $screenshotActions.isEnabled)
                    .help("Show Copy, Annotate, and Save a Copy after native macOS screenshots")
            }
            CommandMenu("Screenshots") {
                Toggle("Enable Screenshot Actions", isOn: $screenshotActions.isEnabled)
                Button("Take Screenshot…") { screenshotActions.takeScreenshot() }
                Button("Scrolling Capture…") { screenshotActions.scrollingCapture() }
                    .disabled(!screenshotActions.isEnabled)
                Button("Open Screenshot…") { screenshotActions.openScreenshot() }
                    .disabled(!screenshotActions.isEnabled)
                Button("Show Screenshot Actions") { screenshotActions.showRecent() }
                    .disabled(!screenshotActions.isEnabled)
            }
            CommandGroup(after: .sidebar) {
                Button("Find") {
                    model.find()
                }
                .keyboardShortcut("f", modifiers: [.command])
                Toggle("Text in Videos", isOn: $model.recognizeVideoText)
            }
            CommandGroup(after: .toolbar) {
                Menu("Sort") {
                    Button("Newest First") { model.sort = .newest }
                    Button("Oldest First") { model.sort = .oldest }
                }
                Button("Rescan Library") {
                    model.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button("Shuffle a Memory") {
                    model.shuffleMemory()
                }
                Divider()
                Button("Zoom In") {
                    model.adjustZoom(by: 20)
                }
                .keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out") {
                    model.adjustZoom(by: -20)
                }
                .keyboardShortcut("-", modifiers: [.command])
                Button(model.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                    model.inspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        MenuBarExtra("Stillroom Screenshots", systemImage: "camera.viewfinder", isInserted: $screenshotActions.isEnabled) {
            Button("Take Screenshot…") { screenshotActions.takeScreenshot() }
            Button("Scrolling Capture…") { screenshotActions.scrollingCapture() }
            Button("Show Screenshot Actions") { screenshotActions.showRecent() }
            if !screenshotActions.captures.isEmpty {
                Menu("Recent Screenshots") {
                    ForEach(screenshotActions.captures) { capture in
                        Button(capture.url.lastPathComponent) {
                            screenshotActions.select(capture)
                        }
                    }
                }
            }
            if let message = screenshotActions.message {
                Text(message)
            }
            Divider()
            Toggle("Screenshot Actions", isOn: $screenshotActions.isEnabled)
            Button("Quit Stillroom") { NSApplication.shared.terminate(nil) }
        }
    }
}

@MainActor
final class StillroomApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasEdits = sender.windows.contains {
            ($0.delegate as? ScreenshotEditorWindowController)?.hasUnsavedChanges == true
        }
        if hasEdits {
            let alert = NSAlert()
            alert.messageText = "Quit with unsaved screenshot edits?"
            alert.informativeText = "Save a copy from each editor to keep your edits. Your original screenshots are unchanged."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Quit and Discard Edits")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        let captures = sender.windows.compactMap { $0.windowController as? ScrollingCaptureWindowController }
        guard !captures.isEmpty else { return .terminateNow }
        Task {
            for capture in captures { await capture.prepareToQuit() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
