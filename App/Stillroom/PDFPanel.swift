import AppKit
import PhotoIndex
import SwiftUI
import UniformTypeIdentifiers

enum PDFMode: String, CaseIterable, Identifiable {
    case photos
    case merge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Photos to PDF"
        case .merge: return "Merge PDFs"
        }
    }
}

struct PDFPageDraft: Identifiable, Equatable {
    var id: String
    var url: URL?
    var photosLocalIdentifier: String?
    var displayName: String
    var date: Date?
    var rotation: QuarterTurns
    var insets: CropInsets
}

struct PDFFileDraft: Identifiable, Equatable {
    var id: String
    var url: URL
    var displayName: String
}

@MainActor
@Observable
final class PDFSession {
    var mode: PDFMode = .photos
    var pages: [PDFPageDraft] = []
    var pdfs: [PDFFileDraft] = []
    var paper: PDFPaper = .a4
    var order: PDFPageOrder = .listed
    var recognizeText = true
    var cleanUp = false
    var besideOriginal = true
    var folderPath: String?
    var fileName = "Pages.pdf"
    var nameTouched = false
    var queue = WorkQueue()
    var running = false
    var notice: String?
    private var worker: Task<Void, Never>?

    func addURLs(_ urls: [URL]) {
        var notes: [String] = []
        for url in urls {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
                notes.append("\(url.lastPathComponent) could not be read.")
                continue
            }
            if directory.boolValue {
                notes.append("\(url.lastPathComponent) is a folder. Drop files.")
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                addPDF(url)
                if mode == .photos {
                    notes.append("\(url.lastPathComponent) is a PDF. It was added under Merge PDFs.")
                }
            } else if ConvertRouting.kind(fileExtension: ext) == .image {
                addImage(url, date: fileDate(url))
                if mode == .merge {
                    notes.append("\(url.lastPathComponent) is an image. It was added under Photos to PDF.")
                }
            } else {
                notes.append("\(url.lastPathComponent) is not a photo or a PDF.")
            }
        }
        notice = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    func addAssets(_ assets: [Asset]) {
        var notes: [String] = []
        for asset in assets {
            if asset.mediaKind == .video || asset.mediaKind == .screenRecording {
                notes.append("\(displayName(asset)) is a video. PDF pages are photos.")
                continue
            }
            if let path = asset.filePath {
                addImage(URL(fileURLWithPath: path), date: asset.createdAt ?? fileDate(URL(fileURLWithPath: path)))
            } else if let local = asset.photosLocalIdentifier {
                if pages.contains(where: { $0.photosLocalIdentifier == local }) { continue }
                pages.append(PDFPageDraft(
                    id: UUID().uuidString,
                    url: nil,
                    photosLocalIdentifier: local,
                    displayName: "Photo \(local.prefix(8))",
                    date: asset.createdAt,
                    rotation: .none,
                    insets: .none
                ))
                suggestName("Photo.pdf")
            }
        }
        if !notes.isEmpty {
            notice = notes.joined(separator: " ")
        }
    }

    func addScans(_ urls: [URL]) {
        let urls = urls
        Task { await self.importScans(urls) }
    }

    private func importScans(_ urls: [URL]) async {
        var pageCount = 0
        var notes: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                do {
                    let directory = try ScanStore.directory()
                    let rendered = try await Task.detached(priority: .utility) {
                        try PDFComposer.renderPages(of: url, into: directory)
                    }.value
                    for page in rendered {
                        addImage(page, date: Date())
                        pageCount += 1
                    }
                } catch {
                    notes.append(error.localizedDescription)
                }
            } else {
                addImage(url, date: Date())
                pageCount += 1
            }
        }
        if pageCount > 0 {
            mode = .photos
            notes.insert("Added \(pageCount) scanned page\(pageCount == 1 ? "" : "s").", at: 0)
        }
        notice = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    func removePage(_ id: String) {
        pages.removeAll { $0.id == id }
    }

    func removePDF(_ id: String) {
        pdfs.removeAll { $0.id == id }
    }

    func movePage(_ id: String, up: Bool) {
        move(&pages, id: id, up: up)
    }

    func movePDF(_ id: String, up: Bool) {
        move(&pdfs, id: id, up: up)
    }

    func rotate(_ id: String, clockwise: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let current = pages[index].rotation
        pages[index].rotation = clockwise ? current.nextClockwise : current.nextCounterClockwise
    }

    func setInset(_ id: String, _ key: WritableKeyPath<CropInsets, Double>, _ value: Double) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].insets[keyPath: key] = value
    }

    func setFileName(_ name: String) {
        fileName = name
        nameTouched = true
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "The PDF is a new file. Originals are not changed."
        guard panel.runModal() == .OK else { return }
        addURLs(panel.urls)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "The PDF is written here. Originals are not changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        folderPath = url.path
        besideOriginal = false
    }

    func start() {
        guard !running else { return }
        if mode == .photos && pages.isEmpty { return }
        if mode == .merge && pdfs.isEmpty { return }
        running = true
        notice = nil
        worker = Task { await self.perform() }
    }

    func stop() {
        worker?.cancel()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func perform() async {
        defer {
            running = false
            worker = nil
        }
        let id = UUID().uuidString
        queue = WorkQueue()
        queue.enqueue(id: id, title: mode == .merge ? "Merged PDF" : fileName)
        queue.markRunning(id)
        let jobDirectory = IndexLocation.temporaryExportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }
        do {
            let output = try outputURL()
            let result: PDFBuildResult
            if mode == .merge {
                let inputs = pdfs.map(\.url)
                result = try await Task.detached(priority: .utility) {
                    try PDFComposer.merge(inputs: inputs, output: output)
                }.value
            } else {
                let specs = try await specs(jobDirectory: jobDirectory)
                let paper = paper
                let text = recognizeText
                let clean = cleanUp
                result = try await Task.detached(priority: .utility) { [weak self] in
                    try PDFComposer.makeDocument(
                        pages: specs,
                        output: output,
                        paper: paper,
                        recognizeText: text,
                        cleanUp: clean
                    ) { done, total in
                        let fraction = total == 0 ? 0 : Double(done) / Double(total)
                        Task { @MainActor in
                            _ = self?.queue.setProgress(id, fraction)
                        }
                    }
                }.value
            }
            if Task.isCancelled {
                queue.finishCancelled(id)
                return
            }
            queue.succeed(id, outputPath: result.outputPath)
            if !result.warnings.isEmpty {
                notice = result.warnings.joined(separator: " ")
            }
        } catch is CancellationError {
            queue.finishCancelled(id)
        } catch {
            queue.fail(id, message: error.localizedDescription)
        }
    }

    private func specs(jobDirectory: URL) async throws -> [PDFImageSpec] {
        var resolved: [PDFPageDraft] = []
        for page in orderedPages() {
            if let url = page.url {
                var copy = page
                copy.url = url
                resolved.append(copy)
                continue
            }
            guard let local = page.photosLocalIdentifier else { continue }
            let url = try await PhotosLibraryClient.exportOriginal(localIdentifier: local, to: jobDirectory)
            var copy = page
            copy.url = url
            copy.displayName = url.lastPathComponent
            resolved.append(copy)
        }
        return resolved.compactMap { page in
            guard let url = page.url else { return nil }
            return PDFImageSpec(url: url, name: page.displayName, rotation: page.rotation, crop: page.insets.rect())
        }
    }

    private func orderedPages() -> [PDFPageDraft] {
        let refs = pages.map { PDFPageRef(id: $0.id, name: $0.displayName, date: $0.date) }
        let ordered = PDFPageOrdering.ordered(refs, by: order)
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        return ordered.compactMap { byID[$0.id] }
    }

    private func outputURL() throws -> URL {
        let directory: String
        if besideOriginal {
            let source = mode == .photos ? pages.compactMap(\.url).first?.path : pdfs.first?.url.path
            guard let source else { throw OutputNameError.needsFolder }
            directory = URL(fileURLWithPath: source).deletingLastPathComponent().path
        } else if let folderPath, !folderPath.isEmpty {
            directory = folderPath
        } else {
            throw OutputNameError.needsFolder
        }
        let suggested = mode == .merge ? "Merged.pdf" : fileName
        let forbidden = pages.compactMap(\.url).map(\.path) + pdfs.map(\.url.path)
        var reserved = Set<String>()
        let path = try OutputNamer.allocate(
            displayName: suggested,
            sourcePath: nil,
            fileExtension: "pdf",
            directory: directory,
            reserved: &reserved,
            exists: { FileManager.default.fileExists(atPath: $0) },
            forbiddenPaths: forbidden
        ).get()
        return URL(fileURLWithPath: path)
    }

    private func addPDF(_ url: URL) {
        if pdfs.contains(where: { $0.url.path == url.path }) { return }
        pdfs.append(PDFFileDraft(id: UUID().uuidString, url: url, displayName: url.lastPathComponent))
    }

    private func addImage(_ url: URL, date: Date?) {
        if pages.contains(where: { $0.url?.path == url.path }) { return }
        pages.append(PDFPageDraft(
            id: UUID().uuidString,
            url: url,
            photosLocalIdentifier: nil,
            displayName: url.lastPathComponent,
            date: date,
            rotation: .none,
            insets: .none
        ))
        suggestName(OutputNamer.stem(of: url.lastPathComponent) + ".pdf")
    }

    private func suggestName(_ name: String) {
        guard !nameTouched, pages.count == 1 else { return }
        fileName = name
    }

    private func displayName(_ asset: Asset) -> String {
        if let path = asset.filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "Photo"
    }

    private func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private func move<T: Identifiable>(_ items: inout [T], id: T.ID, up: Bool) where T.ID == String {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let next = up ? index - 1 : index + 1
        guard items.indices.contains(next) else { return }
        items.swapAt(index, next)
    }
}

struct PDFPanel: View {
    var model: AppModel
    @Bindable var session: PDFSession
    @State private var targeted = false
    @State private var selectedPageID: String?
    @State private var cropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Make PDF")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.inkColor)
                Spacer()
                HStack(spacing: 2) {
                    modeButton(.photos)
                    modeButton(.merge)
                }
                .padding(3)
                .background(Palette.inkColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let notice = session.notice {
                Text(notice)
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 18) {
                if session.mode == .photos {
                    previewColumn
                } else {
                    mergeColumn
                }
                optionsColumn
                    .frame(width: 280)
            }
            if !session.queue.items.isEmpty {
                progress
            }
            HStack {
                Spacer()
                Button("Cancel") { model.presentedTool = nil }
                    .keyboardShortcut(.cancelAction)
                if session.running {
                    Button("Stop") { session.stop() }
                } else {
                    Button("Create PDF") { session.start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentColor)
                        .disabled(session.mode == .photos ? session.pages.isEmpty : session.pdfs.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 920, height: 640)
        .background(Palette.canvasColor)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await FileDrop.urls(from: providers)
                await MainActor.run { session.addURLs(urls) }
            }
            return true
        }
        .onAppear {
            selectedPageID = session.pages.first?.id
        }
        .onChange(of: session.pages.map(\.id)) { _, ids in
            if selectedPageID == nil || !ids.contains(selectedPageID ?? "") {
                selectedPageID = ids.first
            }
        }
    }

    private func modeButton(_ mode: PDFMode) -> some View {
        let on = session.mode == mode
        return Button {
            session.mode = mode
        } label: {
            Text(mode.title)
                .font(StillroomFont.controlMedium)
                .foregroundStyle(on ? Color.white : Palette.inkColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    guard let id = activePageID else { return }
                    session.rotate(id, clockwise: false)
                } label: {
                    Label("Rotate", systemImage: "rotate.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    cropping.toggle()
                } label: {
                    Label("Crop", systemImage: "crop")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(cropping ? Palette.accentColor : nil)
                Spacer()
            }
            .disabled(session.running || activePageID == nil)
            pagePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if cropping, let page = activePage {
                HStack {
                    insetSlider("L", page, \.left)
                    insetSlider("R", page, \.right)
                    insetSlider("T", page, \.top)
                    insetSlider("B", page, \.bottom)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 4) {
                            PDFPageThumb(url: page.url)
                                .frame(width: 54, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(selectedPageID == page.id ? Palette.accentColor : Palette.borderColor, lineWidth: selectedPageID == page.id ? 2 : 1)
                                }
                                .onTapGesture { selectedPageID = page.id }
                            Text("\(index + 1)")
                                .font(StillroomFont.caption)
                                .foregroundStyle(Palette.secondaryColor)
                        }
                        .contextMenu {
                            Button("Move Up") { session.movePage(page.id, up: true) }
                            Button("Move Down") { session.movePage(page.id, up: false) }
                            Button("Remove") { session.removePage(page.id) }
                        }
                    }
                    Button("Add Photos…") { session.chooseFiles() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(session.running)
                }
            }
            HStack {
                Text("\(Format.countPhrase(session.pages.count, singular: "page", plural: "pages")) · Original files stay untouched.")
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                Spacer()
                ContinuityScanButton { urls in
                    session.addScans(urls)
                }
                .frame(width: 140, height: 24)
                .help("Scan with iPhone when a phone on the same Apple ID is nearby.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pagePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.raisedColor)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            if let page = activePage {
                PDFPageThumb(url: page.url)
                    .rotationEffect(rotation(page.rotation))
                    .padding(18)
            } else {
                Text(targeted ? "Drop photos" : "Add photos to start")
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
    }

    private var mergeColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.pdfs.isEmpty {
                Text("No PDFs yet. Drop them here, or add files. They join in the order listed.")
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.pdfs) { file in
                        HStack {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(Palette.accentColor)
                            Text(file.displayName).lineLimit(1)
                            Spacer()
                            Button("Up") { session.movePDF(file.id, up: true) }
                            Button("Down") { session.movePDF(file.id, up: false) }
                            Button {
                                session.removePDF(file.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                        }
                        .font(StillroomFont.control)
                        .buttonStyle(.borderless)
                        .padding(8)
                        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            Button("Add PDFs…") { session.chooseFiles() }
                .buttonStyle(.bordered)
                .disabled(session.running)
            Text("Original files stay untouched.")
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("File name") {
                TextField("File name", text: Binding(get: { session.fileName }, set: { session.setFileName($0) }))
                    .textFieldStyle(.roundedBorder)
            }
            if session.mode == .photos {
                field("Paper size") {
                    Picker("Paper size", selection: $session.paper) {
                        ForEach(PDFPaper.allCases) { paper in
                            Text(paper == .fit ? "Fit to photo" : paper.title).tag(paper)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                field("Page order") {
                    Picker("Page order", selection: $session.order) {
                        Text("Listed order").tag(PDFPageOrder.listed)
                        Text("Name").tag(PDFPageOrder.name)
                        Text("Date").tag(PDFPageOrder.date)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Toggle("Recognize text (OCR)", isOn: $session.recognizeText)
                    .font(StillroomFont.control)
                    .help("Reads the page on this Mac and embeds the words so they can be selected. Nothing is uploaded.")
                Toggle("Clean up scans", isOn: $session.cleanUp)
                    .font(StillroomFont.control)
                    .help("Looks for a page, corrects its perspective, and raises contrast. This runs before the crop.")
            }
            field("Destination") {
                Picker("Destination", selection: $session.besideOriginal) {
                    Text("Choose folder…").tag(false)
                    Text("Next to first original").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !session.besideOriginal {
                    Button("Choose Folder…") { session.chooseFolder() }
                    Text(folderLabel)
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
        .disabled(session.running)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StillroomFont.controlMedium)
                .foregroundStyle(Palette.inkColor)
            content()
        }
    }

    private var folderLabel: String {
        guard let path = session.folderPath, !path.isEmpty else { return "No folder chosen" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var activePageID: String? {
        if let selectedPageID, session.pages.contains(where: { $0.id == selectedPageID }) {
            return selectedPageID
        }
        return session.pages.first?.id
    }

    private var activePage: PDFPageDraft? {
        guard let id = activePageID else { return nil }
        return session.pages.first { $0.id == id }
    }

    private func rotation(_ turns: QuarterTurns) -> Angle {
        switch turns {
        case .none: return .zero
        case .clockwise: return .degrees(90)
        case .half: return .degrees(180)
        case .counterClockwise: return .degrees(-90)
        }
    }

    private func insetSlider(_ label: String, _ page: PDFPageDraft, _ key: WritableKeyPath<CropInsets, Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(StillroomFont.caption).foregroundStyle(Palette.secondaryColor)
            Slider(
                value: Binding(
                    get: { session.pages.first { $0.id == page.id }?.insets[keyPath: key] ?? 0 },
                    set: { session.setInset(page.id, key, $0) }
                ),
                in: 0...0.45
            )
            .tint(Palette.accentColor)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: session.queue.overallProgress)
                .tint(Palette.accentColor)
            ForEach(session.queue.items) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.state == .failed ? "Failed" : (item.state == .succeeded ? "Done" : "Working"))
                        .foregroundStyle(Palette.secondaryColor)
                }
                .font(StillroomFont.caption)
                if let detail = item.detail {
                    Text(detail)
                        .font(StillroomFont.caption)
                        .foregroundStyle(item.state == .failed ? Color.red : Palette.secondaryColor)
                }
                if let path = item.outputPath {
                    Button("Show in Finder") { session.reveal(path) }
                        .buttonStyle(.borderless)
                        .font(StillroomFont.caption)
                }
            }
        }
    }
}

private struct PDFPageThumb: View {
    var url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.borderColor.opacity(0.25)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: url?.path) {
            guard let url else { return }
            image = NSImage(contentsOf: url)
        }
    }
}
