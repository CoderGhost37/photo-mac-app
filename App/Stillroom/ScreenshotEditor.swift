import AppKit
import SwiftUI
import PhotoIndex
import UniformTypeIdentifiers

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private let editor: ScreenshotEditorModel
    var hasUnsavedChanges: Bool { editor.hasUnsavedChanges }

    init(url: URL, onSave: @escaping @MainActor (URL) -> Void) {
        editor = ScreenshotEditorModel(url: url, onSave: onSave)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Edit Screenshot — \(url.lastPathComponent)"
        window.minSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ScreenshotEditorView(model: editor))
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editor.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved screenshot edits?"
        alert.informativeText = "Your original screenshot is unchanged. Save a copy to keep these edits."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Edits")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        editor.discardUnsavedChanges()
        return true
    }
}

private enum ScreenshotTool: String, CaseIterable, Identifiable {
    case select = "Select", crop = "Crop", arrow = "Arrow", text = "Text", redact = "Redact"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .redact: "rectangle.fill"
        }
    }
    var hint: String {
        switch self {
        case .select: "Click an annotation to edit it. Drag to move, or drag its handles to resize."
        case .crop: "Drag to select the area to keep. The dashed outline is your saved crop."
        case .arrow: "Drag from the arrow’s tail toward the detail you want to highlight."
        case .text: "Enter a label, then click where its top left corner should go."
        case .redact: "Drag over sensitive information. The saved image contains solid black pixels."
        }
    }
}

@MainActor
private final class ScreenshotEditorModel: ObservableObject {
    let url: URL
    let onSave: @MainActor (URL) -> Void
    let original: CGImage?
    @Published var preview: CGImage?
    @Published var state = ScreenshotEditState()
    @Published var tool: ScreenshotTool = .select
    @Published var selectedID: UUID?
    @Published var color: ScreenshotColor = .red
    @Published var markSize: CGFloat = 24
    @Published var outputPreview: CGImage?
    @Published var label = ""
    @Published var error: String?
    @Published var status = "Your original stays unchanged."
    @Published private(set) var history = ScreenshotEditHistory()
    private var selectionDrag: (baseline: ScreenshotEditState, start: CGPoint, id: UUID, handle: ScreenshotHandle?)?
    private var savedState = ScreenshotEditState()
    private var controlBaseline: ScreenshotEditState?

    var hasUnsavedChanges: Bool { state != savedState }
    var size: CGSize { original.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var stroke: CGFloat { max(3, size.width / 320) }
    var textSize: CGFloat { max(20, size.width / 48) }

    init(url: URL, onSave: @escaping @MainActor (URL) -> Void) {
        self.url = url
        self.onSave = onSave
        do {
            let image = try ScreenshotEditing.load(url)
            original = image
            preview = image
            outputPreview = image
            markSize = max(3, CGFloat(image.width) / 320)
        } catch {
            original = nil
            self.error = "Could not open this screenshot. \(error.localizedDescription)"
        }
    }

    func change(_ next: ScreenshotEditState) {
        guard next != state else { return }
        if controlBaseline == nil { history.record(state, replacing: next) }
        state = next
        refresh()
    }

    func controlEditingChanged(_ editing: Bool) {
        if editing {
            if controlBaseline == nil { controlBaseline = state }
        } else if let baseline = controlBaseline {
            controlBaseline = nil
            history.record(baseline, replacing: state)
        }
    }

    func finish(from start: CGPoint, to end: CGPoint) {
        var next = state
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .select: return
        case .crop:
            guard rect.width >= 2, rect.height >= 2 else { return }
            next.crop = rect.integral
        case .redact:
            guard rect.width >= 1, rect.height >= 1 else { return }
            next.annotations.append(ScreenshotAnnotation(mark: .redaction(rect)))
        case .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= 3 else { return }
            next.annotations.append(ScreenshotAnnotation(mark: .arrow(from: start, to: end, width: markSize, color: color)))
        case .text:
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { status = "Enter a label before placing text."; return }
            next.annotations.append(ScreenshotAnnotation(mark: .text(text, at: start, size: markSize, color: color)))
        }
        if tool != .crop { selectedID = next.annotations.last?.id }
        change(next)
    }

    var selected: ScreenshotAnnotation? { state.annotations.first { $0.id == selectedID } }

    func beginSelection(at point: CGPoint, tolerance: CGFloat) {
        let handle = selected?.mark.handles.first { hypot($0.value.x - point.x, $0.value.y - point.y) <= tolerance }
        let annotation = handle != nil ? selected : state.annotations.reversed().first { $0.mark.hitTest(point, tolerance: tolerance) }
        selectedID = annotation?.id
        guard let annotation else { selectionDrag = nil; return }
        selectionDrag = (state, point, annotation.id, handle?.key)
    }

    func updateSelection(to point: CGPoint) {
        guard let drag = selectionDrag,
              let baseline = drag.baseline.annotations.first(where: { $0.id == drag.id }),
              let index = state.annotations.firstIndex(where: { $0.id == drag.id }) else { return }
        if point == drag.start {
            state.annotations[index].mark = baseline.mark
            refresh()
            return
        }
        if let handle = drag.handle {
            guard let origin = baseline.mark.handles[handle] else { return }
            let target = CGPoint(x: origin.x + point.x - drag.start.x, y: origin.y + point.y - drag.start.y)
            state.annotations[index].mark = baseline.mark.resized(handle: handle, to: target)
        } else {
            state.annotations[index].mark = baseline.mark.moved(by: CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y), inside: size)
        }
        refresh()
    }

    func endSelection() {
        guard let drag = selectionDrag else { return }
        history.record(drag.baseline, replacing: state)
        selectionDrag = nil
    }

    func editSelected(_ transform: (ScreenshotMark) -> ScreenshotMark) {
        guard let index = state.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        var next = state
        next.annotations[index].mark = transform(next.annotations[index].mark)
        change(next)
    }

    func deleteSelected() {
        var next = state
        next.annotations.removeAll { $0.id == selectedID }
        selectedID = nil
        change(next)
    }

    func setBackground(_ transform: (inout ScreenshotBackground) -> Void) {
        var next = state
        transform(&next.background)
        change(next)
    }

    func discardUnsavedChanges() {
        state = savedState
        history = ScreenshotEditHistory()
        selectedID = nil
        refresh()
    }

    func undo() {
        controlEditingChanged(false)
        guard let previous = history.undo(state) else { return }
        state = previous
        selectedID = nil
        refresh()
    }

    func redo() {
        guard let next = history.redo(state) else { return }
        state = next
        selectedID = nil
        refresh()
    }

    func refresh() {
        guard let original else { return }
        do {
            preview = try ScreenshotEditing.render(original, marks: state.annotations.map(\.mark))
            outputPreview = try rendered()
        }
        catch { self.error = error.localizedDescription }
        status = "Your original stays unchanged."
    }

    func rendered() throws -> CGImage {
        guard let original else { throw CocoaError(.fileReadCorruptFile) }
        return try ScreenshotEditing.render(original, marks: state.annotations.map(\.mark), crop: state.crop, background: state.background)
    }

    func copy() {
        do {
            let data = try ScreenshotEditing.pngData(rendered())
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setData(data, forType: .png) else { throw CocoaError(.fileWriteUnknown) }
            status = "Copied edited image."
        } catch { self.error = "Could not copy the image. \(error.localizedDescription)" }
    }

    func save() {
        let panel = NSSavePanel()
        panel.title = "Save an edited copy"
        panel.message = "A new PNG will be created. Existing files are never replaced; occupied names receive a number."
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " Edited.png"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let output = try ScreenshotEditing.saveCopy(rendered(), suggestedURL: selected, originalURL: url)
            savedState = state
            status = "Saved \(output.lastPathComponent)"
            onSave(output)
        } catch { self.error = "Could not save a copy. \(error.localizedDescription)" }
    }
}

private struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(ScreenshotTool.allCases) { tool in
                    Button {
                        model.tool = tool
                        if tool != .select { model.selectedID = nil }
                        if tool == .text { model.markSize = model.textSize }
                        if tool == .arrow { model.markSize = model.stroke }
                    } label: { Label(tool.rawValue, systemImage: tool.symbol).padding(.vertical, 4) }
                    .buttonStyle(.bordered)
                    .tint(model.tool == tool ? .accentColor : .secondary)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                    .disabled(model.history.undoStates.isEmpty).keyboardShortcut("z", modifiers: .command)
                Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                    .disabled(model.history.redoStates.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Reset") { model.change(ScreenshotEditState()); model.selectedID = nil }
                    .disabled(model.state == ScreenshotEditState())
            }.padding(12)
            Text(model.tool.hint).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                ScrollView { inspector.padding(16) }.frame(width: 240)
            }
            Divider()
            HStack {
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if let output = model.outputPreview {
                    Text("\(output.width) × \(output.height) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Copy Image", systemImage: "doc.on.doc", action: model.copy).disabled(model.original == nil)
                Button("Save a Copy…", action: model.save).buttonStyle(.borderedProminent)
                    .disabled(model.original == nil).keyboardShortcut("s", modifiers: .command)
            }.padding(16)
        }
        .alert("Screenshot Editor", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            if let image = model.preview,
               let fitted = AspectFit.rect(containerWidth: max(1, geometry.size.width - 48), containerHeight: max(1, geometry.size.height - 48), imageWidth: model.size.width, imageHeight: model.size.height) {
                let frame = CGRect(x: fitted.x + 24, y: fitted.y + 24, width: fitted.width, height: fitted.height)
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                    if let crop = model.state.crop { selection(crop, frame: frame, color: .accentColor) }
                    if model.tool == .select, let annotation = model.selected {
                        selection(annotation.mark.bounds, frame: frame, color: .blue)
                        ForEach(ScreenshotHandle.allCases) { handle in
                            if let point = annotation.mark.handles[handle] {
                                let displayed = display(point, frame: frame)
                                Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 2))
                                    .frame(width: 10, height: 10).position(displayed).allowsHitTesting(false)
                            }
                        }
                    }
                    if let start = dragStart, let end = dragEnd, model.tool != .select {
                        if model.tool == .arrow {
                            Path { path in path.move(to: display(start, frame: frame)); path.addLine(to: display(end, frame: frame)) }
                                .stroke(Color(cgColor: model.color.cgColor), style: StrokeStyle(lineWidth: max(2, model.markSize * frame.width / model.size.width), lineCap: .round))
                        } else if model.tool != .text {
                            selection(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)), frame: frame, color: model.tool == .redact ? .black : .accentColor)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frame.contains(value.startLocation) else { return }
                        let start = ScreenshotEditing.pixelPoint(value.startLocation, displayedIn: frame, imageSize: model.size)
                        let end = ScreenshotEditing.pixelPoint(value.location, displayedIn: frame, imageSize: model.size)
                        if dragStart == nil, model.tool == .select {
                            model.beginSelection(at: start, tolerance: 9 * model.size.width / frame.width)
                        }
                        dragStart = start
                        dragEnd = end
                        if model.tool == .select { model.updateSelection(to: end) }
                    }
                    .onEnded { _ in
                        if model.tool == .select { model.endSelection() }
                        else if let start = dragStart, let end = dragEnd { model.finish(from: start, to: end) }
                        dragStart = nil
                        dragEnd = nil
                    })
                .accessibilityLabel("Screenshot canvas. \(model.tool.hint)")
            } else {
                ContentUnavailableView("Screenshot unavailable", systemImage: "photo.badge.exclamationmark", description: Text("Close this window and try another image."))
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.selected == nil ? "Annotation" : "Selected annotation").font(.headline)
            if let selected = model.selected {
                switch selected.mark {
                case let .text(text, point, size, color):
                    TextField("Text", text: Binding(get: { text }, set: { value in
                        model.editSelected { _ in .text(value, at: point, size: size, color: color) }
                    })).textFieldStyle(.roundedBorder)
                    colorPicker(color) { value in model.editSelected { _ in .text(text, at: point, size: size, color: value) } }
                    sizeControl(size, range: 6...200, title: "Text size") { value in model.editSelected { _ in .text(text, at: point, size: value, color: color) } }
                case let .arrow(a, b, width, color):
                    colorPicker(color) { value in model.editSelected { _ in .arrow(from: a, to: b, width: width, color: value) } }
                    sizeControl(width, range: 1...50, title: "Stroke width") { value in model.editSelected { _ in .arrow(from: a, to: b, width: value, color: color) } }
                case .redaction:
                    Text("Opaque black redaction").font(.callout).foregroundStyle(.secondary)
                }
                Button("Delete Annotation", systemImage: "trash", action: model.deleteSelected)
                    .keyboardShortcut(.delete, modifiers: [])
            } else if model.tool == .text || model.tool == .arrow {
                if model.tool == .text {
                    TextField("Text to place", text: $model.label).textFieldStyle(.roundedBorder)
                }
                colorPicker(model.color) { model.color = $0 }
                sizeControl(model.markSize, range: model.tool == .text ? 6...200 : 1...50, title: model.tool == .text ? "Text size" : "Stroke width") { model.markSize = $0 }
            } else {
                Text("Use Select to edit an existing annotation.").font(.callout).foregroundStyle(.secondary)
            }
            if model.state.crop != nil {
                Button("Remove Crop") { var next = model.state; next.crop = nil; model.change(next) }
            }
            Divider()
            Text("Background").font(.headline)
            Picker("Style", selection: Binding(get: { model.state.background.style }, set: { value in model.setBackground { $0.style = value } })) {
                ForEach(ScreenshotBackgroundStyle.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            if model.state.background.style != .none {
                colorPicker(model.state.background.color) { value in model.setBackground { $0.color = value } }
                if model.state.background.style == .gradient {
                    Text("Second color").font(.caption)
                    colorPicker(model.state.background.secondColor) { value in model.setBackground { $0.secondColor = value } }
                }
                sizeControl(model.state.background.padding, range: 0...200, title: "Padding") { value in model.setBackground { $0.padding = value.rounded() } }
                sizeControl(model.state.background.cornerRadius, range: 0...100, title: "Corner radius") { value in model.setBackground { $0.cornerRadius = value.rounded() } }
                Toggle("Shadow", isOn: Binding(get: { model.state.background.shadow }, set: { value in model.setBackground { $0.shadow = value } }))
            }
            Divider()
            Text("Export preview").font(.headline)
            Text("Includes crop and background. Edit annotations on the canvas.").font(.caption).foregroundStyle(.secondary)
            if let output = model.outputPreview {
                Image(decorative: output, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 160)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorPicker(_ selected: ScreenshotColor, set: @escaping (ScreenshotColor) -> Void) -> some View {
        Picker("Color", selection: Binding(get: { selected }, set: set)) {
            ForEach(ScreenshotColor.allCases) { color in
                Text(color.rawValue.capitalized).tag(color)
            }
        }
    }

    private func sizeControl(_ value: CGFloat, range: ClosedRange<CGFloat>, title: String, set: @escaping (CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(Int(value)) px").font(.caption)
            Slider(value: Binding(get: { value }, set: set), in: range, onEditingChanged: model.controlEditingChanged)
                .accessibilityLabel(title)
        }
    }

    private func display(_ point: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x / model.size.width * frame.width, y: frame.minY + point.y / model.size.height * frame.height)
    }

    private func selection(_ rect: CGRect, frame: CGRect, color: Color) -> some View {
        let origin = display(rect.origin, frame: frame)
        let width = rect.width / model.size.width * frame.width
        let height = rect.height / model.size.height * frame.height
        return Rectangle().fill(color.opacity(0.1))
            .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .frame(width: max(1, width), height: max(1, height)).position(x: origin.x + width / 2, y: origin.y + height / 2)
            .allowsHitTesting(false)
    }
}
