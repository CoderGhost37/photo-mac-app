import AppKit
import Foundation
import PhotoIndex

/// UI state for the library window. Indexing runs on a utility queue and only reads files.
@MainActor
@Observable
final class AppModel {
    private(set) var sources: [Source] = []
    private(set) var counts = LibraryCounts.empty
    private(set) var assets: [Asset] = []
    private(set) var matchedCount = 0
    private(set) var selectedAsset: Asset?
    var selectedSourceID: String?
    var selectedKind: MediaKind?
    var thumbnailSide: Double = 144
    var inspectorVisible = true
    var status = "Opening library…"
    var isIndexing = false

    private let database: IndexDatabase?
    private let indexer: Indexer?
    let thumbnails: ThumbnailService?
    private let scanQueue = DispatchQueue(label: "Stillroom.Index", qos: .utility)
    private var watcher: FolderWatcher?
    private var debounce: [String: DispatchWorkItem] = [:]
    private var accessedURLs: [URL] = []
    private var jobs = 0
    private var didStart = false
    private var reloadGeneration = 0
    private var launchError: String?
    private var keepStatus = false
    var selectedAssetID: String?

    var filterTitle: String {
        var parts: [String] = []
        if let selectedSourceID, let source = sources.first(where: { $0.id == selectedSourceID }) {
            parts.append(source.displayName)
        }
        if let selectedKind {
            parts.append(Format.mediaTitle(selectedKind))
        }
        return parts.isEmpty ? "All Items" : parts.joined(separator: " · ")
    }

    var queryToken: String {
        "\(selectedSourceID ?? "*")|\(selectedKind?.rawValue ?? "*")"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let database = try IndexDatabase(path: IndexLocation.databaseURL(home: home).path)
            self.database = database
            self.indexer = Indexer(database: database, metadataReader: AppleMetadataReader())
            let cache = ThumbnailCache(directory: IndexLocation.thumbnailDirectory(home: home))
            self.thumbnails = ThumbnailService(cache: cache)
        } catch {
            self.database = nil
            self.indexer = nil
            self.thumbnails = nil
            self.launchError = error.localizedDescription
            self.status = error.localizedDescription
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        guard database != nil else { return }
        do {
            try prepareSources()
        } catch {
            status = error.localizedDescription
        }
        restartWatcher()
        reload()
        for source in sources where source.enabled {
            scheduleScan(source)
        }
    }

    func selectAll() {
        selectedSourceID = nil
        selectedKind = nil
        reload()
    }

    func select(kind: MediaKind) {
        selectedKind = selectedKind == kind ? nil : kind
        reload()
    }

    func select(sourceID: String) {
        selectedSourceID = selectedSourceID == sourceID ? nil : sourceID
        reload()
    }

    func setEnabled(_ enabled: Bool, sourceID: String) {
        guard let database, var source = sources.first(where: { $0.id == sourceID }) else { return }
        source.enabled = enabled
        do {
            try database.save(source: source)
        } catch {
            status = error.localizedDescription
            return
        }
        if let index = sources.firstIndex(where: { $0.id == sourceID }) {
            sources[index] = source
        }
        restartWatcher()
        if enabled {
            scheduleScan(source)
        }
        reload()
    }

    func addFolder() {
        guard let database else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        panel.message = "Stillroom only reads this folder. Nothing is moved or changed."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = SourceCatalog.normalizedDirectory(url).path
        if sources.contains(where: { $0.kind == .folder && $0.rootPath == path }) {
            status = "That folder is already a source."
            return
        }
        let bookmark = try? FolderAccess.bookmark(for: url)
        _ = url.startAccessingSecurityScopedResource()
        accessedURLs.append(url)
        let source = SourceCatalog.customFolder(
            displayName: url.lastPathComponent,
            rootPath: path,
            bookmarkData: bookmark
        )
        do {
            try database.save(source: source)
            sources = try database.sources()
        } catch {
            status = error.localizedDescription
            return
        }
        selectedSourceID = source.id
        restartWatcher()
        scheduleScan(source)
        reload()
    }

    func removeFolder(_ source: Source) {
        guard source.kind == .folder, let database else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(source.displayName) from Stillroom?"
        alert.informativeText = "The folder stays on disk. Stillroom only forgets the index entry for it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try database.deleteSource(id: source.id)
            sources = try database.sources()
        } catch {
            status = error.localizedDescription
            return
        }
        if selectedSourceID == source.id {
            selectedSourceID = nil
        }
        if selectedAsset?.sourceID == source.id {
            selectedAssetID = nil
            selectedAsset = nil
        }
        restartWatcher()
        reload()
    }

    func select(asset: Asset) {
        selectedAssetID = asset.id
        selectedAsset = asset
    }

    func open(_ asset: Asset) {
        guard let path = asset.filePath else {
            openPhotosApp()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ asset: Asset) {
        guard let path = asset.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openPhotosApp() {
        let photos = URL(fileURLWithPath: "/System/Applications/Photos.app")
        NSWorkspace.shared.open(photos)
    }

    private func prepareSources() throws {
        guard let database else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let capture = ScreenshotLocation.current(home: home)
        _ = try database.synchronizeBuiltinSources(homeDirectory: home, captureDirectory: capture)
        var stored = try database.sources()
        for index in stored.indices where stored[index].kind == .folder {
            guard let data = stored[index].bookmarkData, let resolved = FolderAccess.resolve(data) else { continue }
            stored[index].rootPath = SourceCatalog.normalizedDirectory(resolved.url).path
            if resolved.isStale, let refreshed = try? FolderAccess.bookmark(for: resolved.url) {
                stored[index].bookmarkData = refreshed
            }
            try database.save(source: stored[index])
            accessedURLs.append(resolved.url)
        }
        sources = try database.sources()
    }

    private func restartWatcher() {
        let paths = sources.filter { $0.enabled && $0.isFolderBacked }.compactMap(\.rootPath)
        if watcher == nil {
        watcher = FolderWatcher { [weak self] path in
            Task { @MainActor in
                self?.handleFileEvent(path)
            }
        }
        }
        watcher?.start(paths: paths)
    }

    private func handleFileEvent(_ path: String) {
        let matches = sources.filter { source in
            guard source.enabled, let root = source.rootPath else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
        for source in matches {
            debounce[source.id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.scheduleScan(source)
                }
            }
            debounce[source.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    private func scheduleScan(_ source: Source) {
        guard let indexer, let database else { return }
        beginJob()
        status = "Indexing \(source.displayName)…"
        let name = source.displayName
        let relay = StatusRelay { [weak self] text in
            Task { @MainActor in
                self?.status = text
            }
        }
        scanQueue.async { [weak self] in
            let group = DispatchGroup()
            group.enter()
            var outcome: Result<ScanStats, Error> = .success(.zero)
            Task {
                do {
                    if source.kind == .photosLibrary {
                        outcome = .success(try await Self.scanPhotos(source: source, indexer: indexer, database: database))
                    } else {
                        let stats = try await indexer.scan(source) { examined, total in
                            relay.send("Indexing \(name) · \(examined) of \(total)")
                        }
                        outcome = .success(stats)
                    }
                } catch {
                    outcome = .failure(error)
                }
                group.leave()
            }
            group.wait()
            Task { @MainActor in
                self?.finishScan(name: name, outcome: outcome)
            }
        }
    }

    nonisolated private static func scanPhotos(source: Source, indexer: Indexer, database: IndexDatabase) async throws -> ScanStats {
        let status = await PhotosLibraryClient.requestAccess()
        guard status == .authorized || status == .limited else {
            throw IndexError.sourceRootMissing("Photos library (access is off)")
        }
        let incoming = PhotosLibraryClient.fetchAssets()
        let existing = try database.assets(sourceID: source.id)
        return try indexer.applyPhotosLibrary(existing: existing, incoming: incoming, sourceID: source.id)
    }

    private func finishScan(name: String, outcome: Result<ScanStats, Error>) {
        switch outcome {
        case .failure(let error):
            status = "\(name): \(error.localizedDescription)"
            keepStatus = true
        case .success:
            keepStatus = false
        }
        endJob()
        reload()
    }

    private func beginJob() {
        jobs += 1
        isIndexing = true
    }

    private func endJob() {
        jobs = max(0, jobs - 1)
        isIndexing = jobs > 0
        if !isIndexing, launchError == nil, !keepStatus {
            status = "Library is up to date"
        }
    }

    private func reload() {
        guard let database else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let query = makeQuery()
        let enabled = sources.filter(\.enabled).map(\.id)
        let selectedID = selectedAssetID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let assets = (try? database.fetchAssets(matching: query)) ?? []
            let total = (try? database.countAssets(matching: query)) ?? assets.count
            let counts = (try? database.libraryCounts(enabledSourceIDs: enabled)) ?? .empty
            let selected = selectedID.flatMap { try? database.asset(id: $0) }
            Task { @MainActor in
                guard let self, generation == self.reloadGeneration else { return }
                self.assets = assets
                self.matchedCount = total
                self.counts = counts
                if let selected, query.sourceIDs.contains(selected.sourceID),
                   query.mediaKind == nil || query.mediaKind == selected.mediaKind {
                    self.selectedAsset = selected
                    self.selectedAssetID = selected.id
                } else if selectedID != nil, !assets.contains(where: { $0.id == selectedID }) {
                    self.selectedAsset = nil
                    self.selectedAssetID = nil
                }
            }
        }
    }

    private func makeQuery() -> LibraryQuery {
        let enabled = sources.filter(\.enabled).map(\.id)
        let sourceIDs: [String]
        if let selectedSourceID {
            sourceIDs = [selectedSourceID]
        } else {
            sourceIDs = enabled
        }
        return LibraryQuery(sourceIDs: sourceIDs, mediaKind: selectedKind)
    }
}

private final class StatusRelay: @unchecked Sendable {
    private let handler: (String) -> Void

    init(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    func send(_ text: String) {
        handler(text)
    }
}
