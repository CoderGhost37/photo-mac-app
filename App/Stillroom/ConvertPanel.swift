import AppKit
import PhotoIndex
import SwiftUI
import UniformTypeIdentifiers

struct ConvertFile: Identifiable, Equatable {
    var id: String
    var displayName: String
    var path: String?
    var photosLocalIdentifier: String?
    var fileExtension: String
}

@MainActor
@Observable
final class ConvertSession {
    var inputs: [ConvertFile] = []
    var format: ConvertFormat = .jpeg
    var besideOriginal = true
    var folderPath: String?
    var queue = WorkQueue()
    var running = false
    var notice: String?
    private(set) var stillAvailability: [EncodeAvailability] = []
    private(set) var hevcAvailability = EncodeAvailability(format: .hevc, available: true, unavailableReason: nil)
    private var worker: Task<Void, Never>?

    var place: OutputPlace {
        if besideOriginal { return .besideSource }
        return .folder(folderPath ?? "")
    }

    func refreshAvailability() {
        stillAvailability = ImageEncodeProbe.currentAvailability()
        hevcAvailability = MovieEncodeProbe.hevcAvailability()
        if availability(for: format).available == false {
            format = .jpeg
        }
    }

    func availability(for format: ConvertFormat) -> EncodeAvailability {
        switch format {
        case .hevc:
            return hevcAvailability
        case .mp4, .m4a:
            return EncodeAvailability(format: format, available: true, unavailableReason: nil)
        default:
            return stillAvailability.first { $0.format == format }
                ?? EncodeAvailability(format: format, available: false, unavailableReason: "\(format.title) cannot be written on this Mac.")
        }
    }

    func canUse(_ format: ConvertFormat) -> Bool {
        guard availability(for: format).available else { return false }
        if inputs.isEmpty { return true }
        return inputs.contains { ConvertRouting.allows(format, fileExtension: $0.fileExtension) }
    }

    var blockedNotes: [String] {
        var lines: [String] = []
        for row in stillAvailability where !row.available {
            if let reason = row.unavailableReason, !lines.contains(reason) {
                lines.append(reason)
            }
        }
        if !hevcAvailability.available, let reason = hevcAvailability.unavailableReason {
            lines.append(reason)
        }
        return lines
    }

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
            if inputs.contains(where: { $0.path == url.path }) { continue }
            inputs.append(ConvertFile(
                id: UUID().uuidString,
                displayName: url.lastPathComponent,
                path: url.path,
                photosLocalIdentifier: nil,
                fileExtension: url.pathExtension
            ))
        }
        notice = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    func addAssets(_ assets: [Asset]) {
        for asset in assets {
            if let path = asset.filePath {
                addURLs([URL(fileURLWithPath: path)])
                continue
            }
            guard let local = asset.photosLocalIdentifier else { continue }
            if inputs.contains(where: { $0.photosLocalIdentifier == local }) { continue }
            let video = asset.mediaKind == .video || asset.mediaKind == .screenRecording
            inputs.append(ConvertFile(
                id: UUID().uuidString,
                displayName: "Photo \(local.prefix(8))",
                path: nil,
                photosLocalIdentifier: local,
                fileExtension: video ? "mov" : "jpg"
            ))
        }
    }

    func remove(_ id: String) {
        inputs.removeAll { $0.id == id }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Converted files are written here. Originals are not changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        folderPath = url.path
        besideOriginal = false
    }

    func preview() -> [PlannedConversion] {
        ConvertPlanner.plan(
            inputs: inputs.map {
                ConvertPlanInput(displayName: $0.displayName, sourcePath: $0.path, fileExtension: $0.fileExtension)
            },
            format: format,
            place: place,
            encode: availability(for: format),
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    func start() {
        guard !running, !inputs.isEmpty else { return }
        running = true
        notice = nil
        let files = inputs
        let format = format
        let place = place
        worker = Task { await self.perform(files: files, format: format, place: place) }
    }

    func stop() {
        worker?.cancel()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func perform(files: [ConvertFile], format: ConvertFormat, place: OutputPlace) async {
        defer {
            running = false
            worker = nil
        }
        let jobDirectory = IndexLocation.temporaryExportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }
        var concrete: [ConvertPlanInput] = []
        var early: [(String, String)] = []
        for file in files {
            if Task.isCancelled { break }
            if let local = file.photosLocalIdentifier {
                if case .besideSource = place {
                    early.append((file.displayName, OutputNameError.needsFolder.errorDescription ?? "Choose a folder."))
                    continue
                }
                do {
                    let url = try await PhotosLibraryClient.exportOriginal(localIdentifier: local, to: jobDirectory)
                    concrete.append(ConvertPlanInput(
                        displayName: url.lastPathComponent,
                        sourcePath: url.path,
                        fileExtension: url.pathExtension
                    ))
                } catch {
                    early.append((file.displayName, error.localizedDescription))
                }
            } else {
                concrete.append(ConvertPlanInput(
                    displayName: file.displayName,
                    sourcePath: file.path,
                    fileExtension: file.fileExtension
                ))
            }
        }
        let planned = ConvertPlanner.plan(
            inputs: concrete,
            format: format,
            place: place,
            encode: availability(for: format),
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        queue = WorkQueue()
        struct Job {
            var id: String
            var source: String
            var output: String
        }
        var jobs: [Job] = []
        for (name, message) in early {
            let id = UUID().uuidString
            queue.enqueue(id: id, title: name)
            queue.fail(id, message: message)
        }
        for row in planned {
            let id = UUID().uuidString
            queue.enqueue(id: id, title: row.displayName)
            if let reason = row.skipReason {
                queue.fail(id, message: reason)
            } else if let source = row.sourcePath, let output = row.outputPath {
                jobs.append(Job(id: id, source: source, output: output))
            } else {
                queue.fail(id, message: "Could not choose a destination.")
            }
        }
        for job in jobs {
            if Task.isCancelled {
                _ = queue.cancelQueued()
                break
            }
            guard queue.markRunning(job.id) else { continue }
            do {
                try await convert(source: job.source, output: job.output, format: format, id: job.id)
                if Task.isCancelled {
                    queue.finishCancelled(job.id)
                    _ = queue.cancelQueued()
                    break
                }
                queue.succeed(job.id, outputPath: job.output)
            } catch is CancellationError {
                queue.finishCancelled(job.id)
                _ = queue.cancelQueued()
                break
            } catch {
                queue.fail(job.id, message: error.localizedDescription)
            }
        }
    }

    private func convert(source: String, output: String, format: ConvertFormat, id: String) async throws {
        let inputURL = URL(fileURLWithPath: source)
        let outputURL = URL(fileURLWithPath: output)
        let kind = ConvertRouting.kind(fileExtension: inputURL.pathExtension)
        if kind == .video && format.acceptsVideo {
            let work = Task.detached(priority: .utility) { [weak self] in
                try await MovieTranscoder.export(input: inputURL, output: outputURL, format: format) { value in
                    Task { @MainActor in
                        _ = self?.queue.setProgress(id, value)
                    }
                }
            }
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            return
        }
        let work = Task.detached(priority: .utility) {
            try StillImageTranscoder.convert(input: inputURL, output: outputURL, format: format)
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

struct ConvertPanel: View {
    var model: AppModel
    @Bindable var session: ConvertSession
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            dropZone
            if let notice = session.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            fileList
            formats
            destination
            if session.queue.items.isEmpty {
                summary
            } else {
                progress
            }
            buttons
        }
        .padding(20)
        .frame(width: 640, height: 720)
        .background(Palette.canvasColor)
        .onAppear { session.refreshAvailability() }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await FileDrop.urls(from: providers)
                await MainActor.run { session.addURLs(urls) }
            }
            return true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Convert")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.inkColor)
            Text("Writes a new file. The original stays where it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(targeted ? "Drop to add" : "Drop photos or videos")
                .font(.callout.weight(.medium))
            Text("Or add the files selected in the grid.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if session.inputs.isEmpty {
                    Text("No files yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.inputs) { file in
                    HStack {
                        Text(file.displayName)
                            .lineLimit(1)
                        Spacer()
                        Button("Remove") { session.remove(file.id) }
                            .buttonStyle(.borderless)
                            .disabled(session.running)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 120)
    }

    private var formats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Images")
                .font(.caption)
                .foregroundStyle(.secondary)
            formatRow(ConvertFormat.stillTargets)
            Text("Video and audio")
                .font(.caption)
                .foregroundStyle(.secondary)
            formatRow(ConvertFormat.videoTargets)
            ForEach(session.blockedNotes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func formatRow(_ formats: [ConvertFormat]) -> some View {
        HStack(spacing: 6) {
            ForEach(formats) { format in
                Button(format.title) { session.format = format }
                    .buttonStyle(.bordered)
                    .tint(session.format == format ? Palette.accentColor : Color.secondary)
                    .disabled(!session.canUse(format) || session.running)
                    .help(help(format))
            }
        }
    }

    private func help(_ format: ConvertFormat) -> String {
        if let reason = session.availability(for: format).unavailableReason {
            return reason
        }
        return format.detail
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Destination", selection: $session.besideOriginal) {
                Text("Next to each original").tag(true)
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

    private var summary: some View {
        let rows = session.preview()
        let ready = rows.filter { $0.outputPath != nil }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(ready == 0 ? "Nothing will be written yet." : "\(ready) new file\(ready == 1 ? "" : "s") will be written.")
                .font(.callout)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let reason = row.skipReason {
                    Text("\(row.displayName): \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: session.queue.overallProgress)
            ForEach(session.queue.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text(label(item))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let path = item.outputPath {
                        Button("Show in Finder") { session.reveal(path) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func label(_ item: WorkItem) -> String {
        switch item.state {
        case .queued: return "Waiting"
        case .running: return "Working"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
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
                Button("Convert") { session.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.inputs.isEmpty || !session.availability(for: session.format).available)
            }
            Button("Close") { model.presentedTool = nil }
        }
    }
}
