import SwiftUI

@main
struct StillroomApp: App {
    @State private var model = AppModel()

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
        .defaultSize(width: 1280, height: 820)
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
    }
}
