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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PDF")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.inkColor)
            Text("One photo per page, or several PDFs joined into a new file. Nothing you drop is modified.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Tool", selection: $session.mode) {
                ForEach(PDFMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            dropZone
            if let notice = session.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.mode == .photos {
                photoOptions
                pageList
            } else {
                pdfList
            }
            destination
            if !session.queue.items.isEmpty {
                progress
            }
            buttons
        }
        .padding(20)
        .frame(width: 680, height: 760)
        .background(Palette.canvasColor)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await FileDrop.urls(from: providers)
                await MainActor.run { session.addURLs(urls) }
            }
            return true
        }
    }

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(targeted ? "Drop to add" : (session.mode == .photos ? "Drop photos" : "Drop PDFs"))
                .font(.callout.weight(.medium))
            HStack(spacing: 12) {
                Text("Scan with iPhone uses Continuity Camera when a phone is nearby on the same Apple ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ContinuityScanButton { urls in
                    session.addScans(urls)
                }
                .frame(width: 150, height: 28)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    targeted ? Palette.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
    }

    private var photoOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Page", selection: $session.paper) {
                    ForEach(PDFPaper.allCases) { paper in
                        Text(paper.title).tag(paper)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("Order", selection: $session.order) {
                    ForEach(PDFPageOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            Toggle("Searchable text", isOn: $session.recognizeText)
                .help("Reads the page on this Mac and embeds the words so they can be selected. Nothing is uploaded.")
            Toggle("Straighten documents", isOn: $session.cleanUp)
                .help("Looks for a page, corrects its perspective, and raises contrast. This runs before the crop.")
            TextField("File name", text: Binding(get: { session.fileName }, set: { session.setFileName($0) }))
                .textFieldStyle(.roundedBorder)
        }
        .disabled(session.running)
    }

    private var pageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.pages.isEmpty {
                    Text("No pages yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.pages) { page in
                    pageRow(page)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func pageRow(_ page: PDFPageDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(page.displayName).lineLimit(1)
                Spacer()
                Button("Up") { session.movePage(page.id, up: true) }
                Button("Down") { session.movePage(page.id, up: false) }
                Button("Left") { session.rotate(page.id, clockwise: false) }
                Button("Right") { session.rotate(page.id, clockwise: true) }
                Button("Remove") { session.removePage(page.id) }
            }
            .buttonStyle(.borderless)
            HStack {
                Text("Crop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                insetSlider("L", page, \.left)
                insetSlider("R", page, \.right)
                insetSlider("T", page, \.top)
                insetSlider("B", page, \.bottom)
            }
        }
    }

    private func insetSlider(_ label: String, _ page: PDFPageDraft, _ key: WritableKeyPath<CropInsets, Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { session.pages.first { $0.id == page.id }?.insets[keyPath: key] ?? 0 },
                    set: { session.setInset(page.id, key, $0) }
                ),
                in: 0...0.45
            )
        }
    }

    private var pdfList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if session.pdfs.isEmpty {
                    Text("No PDFs yet. Pages stay in the order listed here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.pdfs) { file in
                    HStack {
                        Text(file.displayName).lineLimit(1)
                        Spacer()
                        Button("Up") { session.movePDF(file.id, up: true) }
                        Button("Down") { session.movePDF(file.id, up: false) }
                        Button("Remove") { session.removePDF(file.id) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Destination", selection: $session.besideOriginal) {
                Text("Next to the first file").tag(true)
                Text("A folder").tag(false)
            }
            .pickerStyle(.radioGroup)
            .disabled(session.running)
            HStack {
                Button("Choose Folder…") { session.chooseFolder() }
                    .disabled(session.running)
                Text(session.folderPath ?? "No folder chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: session.queue.overallProgress)
            ForEach(session.queue.items) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.state == .failed ? "Failed" : (item.state == .succeeded ? "Done" : "Working"))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                }
                if let path = item.outputPath {
                    Button("Show in Finder") { session.reveal(path) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("Add Selection") { session.addAssets(model.selectedAssets) }
                .disabled(model.selectedAssets.isEmpty || session.running)
            Spacer()
            if session.running {
                Button("Stop") { session.stop() }
            } else {
                Button("Export PDF") { session.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.mode == .photos ? session.pages.isEmpty : session.pdfs.isEmpty)
            }
            Button("Close") { model.presentedTool = nil }
        }
    }
}
