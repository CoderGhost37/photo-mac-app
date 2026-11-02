import SwiftUI

@main
struct StillroomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task { model.start() }
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
        }
    }
}
