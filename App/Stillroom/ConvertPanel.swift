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

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Converted files are new copies. Originals are not changed."
        guard panel.runModal() == .OK else { return }
        addURLs(panel.urls)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.inkColor)
                    Text("Create new copies in another format.")
                        .font(StillroomFont.metadata)
                        .foregroundStyle(Palette.secondaryColor)
                }
                Spacer()
            }
            .padding(.bottom, 16)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(session.inputs) { file in
                                convertRow(file)
                            }
                        }
                    }
                    dropZone
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    optionCard
                }
                .frame(width: 280)
            }
            if let notice = session.notice {
                Text(notice)
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .padding(.top, 8)
            }
            if !session.queue.items.isEmpty {
                progress
                    .padding(.top, 8)
            }
            HStack {
                Text("Creates new files. Originals are never changed.")
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                Spacer()
                Button("Cancel") { model.presentedTool = nil }
                    .keyboardShortcut(.cancelAction)
                if session.running {
                    Button("Stop") { session.stop() }
                } else {
                    Button(convertTitle) { session.start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentColor)
                        .disabled(session.inputs.isEmpty || !session.availability(for: session.format).available)
                }
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 860, height: 560)
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

    private var convertTitle: String {
        let count = session.inputs.count
        return count == 1 ? "Convert 1 File" : "Convert \(count) Files"
    }

    private func convertRow(_ file: ConvertFile) -> some View {
        HStack(spacing: 10) {
            ConvertThumb(path: file.path)
                .frame(width: 54, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                    .font(StillroomFont.controlMedium)
                    .foregroundStyle(Palette.inkColor)
                    .lineLimit(1)
                if let path = file.path, let bytes = fileByteCount(path) {
                    Text(Format.bytes(bytes))
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                }
            }
            Spacer(minLength: 4)
            Button {
                session.remove(file.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.secondaryColor)
            }
            .buttonStyle(.plain)
            .disabled(session.running)
        }
        .padding(6)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundStyle(Palette.secondaryColor)
            Text(targeted ? "Drop to add" : "Drop more files here")
                .font(StillroomFont.control)
                .foregroundStyle(Palette.inkColor)
            Button("Add Files…") { session.chooseFiles() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.running)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    targeted ? Palette.accentColor : Palette.borderColor,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
    }

    private var optionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Output format")
                    .font(StillroomFont.controlMedium)
                    .foregroundStyle(Palette.inkColor)
                Picker("Output format", selection: $session.format) {
                    ForEach(ConvertFormat.stillTargets) { format in
                        Text(format.title).tag(format)
                    }
                    Divider()
                    ForEach(ConvertFormat.videoTargets) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .disabled(session.running)
                .labelsHidden()
                ForEach(session.blockedNotes, id: \.self) { note in
                    Text(note)
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Save to")
                    .font(StillroomFont.controlMedium)
                    .foregroundStyle(Palette.inkColor)
                Picker("Save to", selection: $session.besideOriginal) {
                    Text("Next to originals").tag(true)
                    Text("Choose folder…").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(session.running)
                if !session.besideOriginal {
                    Button("Choose Folder…") { session.chooseFolder() }
                        .disabled(session.running)
                    Text(session.folderPath ?? "No folder chosen")
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Output preview")
                    .font(StillroomFont.controlMedium)
                    .foregroundStyle(Palette.inkColor)
                Text(previewName)
                    .font(StillroomFont.path)
                    .foregroundStyle(Palette.secondaryColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            let skipped = session.preview().filter { $0.skipReason != nil }
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, row in
                if let reason = row.skipReason {
                    Text("\(row.displayName): \(reason)")
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
    }

    private var previewName: String {
        guard let row = session.preview().first(where: { $0.outputPath != nil }), let path = row.outputPath else {
            return "—"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: session.queue.overallProgress)
                .tint(Palette.accentColor)
            ForEach(session.queue.items) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(label(item))
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

    private func label(_ item: WorkItem) -> String {
        switch item.state {
        case .queued: return "Waiting"
        case .running: return "Working"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    private func fileByteCount(_ path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}

private struct ConvertThumb: View {
    var path: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.borderColor.opacity(0.4)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: path) {
            guard let path else { return }
            image = NSImage(contentsOf: URL(fileURLWithPath: path))
        }
    }
}
