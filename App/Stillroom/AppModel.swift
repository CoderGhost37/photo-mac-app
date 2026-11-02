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
    var browse: LibraryBrowse = .library
    var placeMemberIDs: [String]?
    var selectedSubjectID: String?
    var selectedStoryID: String?
    var selectedDuplicateID: String?
    private(set) var mapPoints: [GeoPoint] = []
    private(set) var subjectClusters: [SubjectClusterRecord] = []
    private(set) var stories: [HighlightStory] = []
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var gridBlocks: [GridBlock]?
    var playingStory: HighlightStory?
    var playingIndex = 0
    var playingStarted = Date()
    private(set) var shownStory: HighlightStory?
    var thumbnailSide: Double = 144
    var inspectorVisible = true
    var status = "Opening library…"
    var isIndexing = false

    private let database: IndexDatabase?
    private let indexer: Indexer?
    private let recognition: RecognitionService?
    private let understanding: UnderstandingService?
    let thumbnails: ThumbnailService?
    private let scanQueue = DispatchQueue(label: "Stillroom.Index", qos: .utility)
    private var watcher: FolderWatcher?
    private var debounce: [String: DispatchWorkItem] = [:]
    private var accessedURLs: [URL] = []
    private var jobs = 0
    private var didStart = false
    private var reloadGeneration = 0
    private var memoryGeneration = 0
    private var launchError: String?
    private var keepStatus = false
    private var searchDebounce: DispatchWorkItem?
    private static let videoTextKey = "Stillroom.recognizeVideoText"
    var selectedAssetID: String?
    private(set) var selectedAssets: [Asset] = []
    var presentedTool: WorkspaceTool?
    var searchText = ""
    private(set) var searchPlan = SearchPlan.inactive
    var hoveredTextHitID: Int64?
    private(set) var findToken = 0
    var recognizeVideoText = UserDefaults.standard.bool(forKey: AppModel.videoTextKey) {
        didSet {
            UserDefaults.standard.set(recognizeVideoText, forKey: Self.videoTextKey)
            recognition?.schedule(includeVideoKeyframes: recognizeVideoText)
        }
    }
    let convertSession = ConvertSession()
    let pdfSession = PDFSession()

    var filterTitle: String {
        switch browse {
        case .places:
            return "Places"
        case .people:
            if let selectedSubjectID, let cluster = subjectClusters.first(where: { $0.id == selectedSubjectID }) {
                return displayName(for: cluster)
            }
            return "People & Pets"
        case .highlights:
            if let playingStory, playingStory.id == selectedStoryID {
                return playingStory.title
            }
            if let selectedStoryID, let story = stories.first(where: { $0.id == selectedStoryID }) {
                return story.title
            }
            return "Highlights"
        case .duplicates:
            return "Duplicates"
        case .library:
            var parts: [String] = []
            if let selectedSourceID, let source = sources.first(where: { $0.id == selectedSourceID }) {
                parts.append(source.displayName)
            }
            if let selectedKind {
                parts.append(Format.mediaTitle(selectedKind))
            }
            return parts.isEmpty ? "All Items" : parts.joined(separator: " · ")
        }
    }

    var queryToken: String {
        let blocks = gridBlocks?.map(\.id).joined(separator: ",") ?? ""
        return "\(browse.rawValue)|\(selectedSourceID ?? "*")|\(selectedKind?.rawValue ?? "*")|\(searchText)|\(selectedSubjectID ?? "")|\(selectedStoryID ?? "")|\(selectedDuplicateID ?? "")|\(placeMemberIDs?.count ?? -1)|\(blocks)"
    }

    var isSearching: Bool { searchPlan.isActive }

    var smartSearchReady: Bool {
        ClipInstall.isComplete(directory: ClipModel.resolve(
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundle: .main
        ))
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let database = try IndexDatabase(path: IndexLocation.databaseURL(home: home).path)
            self.database = database
            self.indexer = Indexer(database: database, metadataReader: AppleMetadataReader())
            self.recognition = RecognitionService(database: database, home: home)
            self.understanding = UnderstandingService(database: database, home: home)
            let cache = ThumbnailCache(directory: IndexLocation.thumbnailDirectory(home: home))
            self.thumbnails = ThumbnailService(cache: cache)
        } catch {
            self.database = nil
            self.indexer = nil
            self.recognition = nil
            self.understanding = nil
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
        let progress: @Sendable (String?) -> Void = { [weak self] text in
            Task { @MainActor in
                guard let self, !self.isIndexing, !self.keepStatus else { return }
                self.status = text ?? "Library is up to date"
            }
        }
        recognition?.onProgress = progress
        understanding?.onProgress = progress
        understanding?.onUpdate = { [weak self] in
            Task { @MainActor in
                self?.refreshMemories()
            }
        }
        restartWatcher()
        refreshMemories()
        for source in sources where source.enabled {
            scheduleScan(source)
        }
        recognition?.schedule(includeVideoKeyframes: recognizeVideoText)
        understanding?.schedule()
    }

    func find() {
        findToken += 1
    }

    func searchChanged() {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.reload()
            }
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func textHits(for asset: Asset) -> [TextHit] {
        (try? database?.textHits(assetID: asset.id)) ?? []
    }

    func selectAll() {
        browse = .library
        selectedSourceID = nil
        selectedKind = nil
        clearPins()
        reload()
    }

    func select(kind: MediaKind) {
        browse = .library
        clearPins()
        selectedKind = selectedKind == kind ? nil : kind
        reload()
    }

    func select(sourceID: String) {
        browse = .library
        clearPins()
        selectedSourceID = selectedSourceID == sourceID ? nil : sourceID
        reload()
    }

    func selectPlaces() {
        browse = .places
        selectedKind = nil
        selectedSubjectID = nil
        selectedStoryID = nil
        selectedDuplicateID = nil
        placeMemberIDs = nil
        shownStory = nil
        stopStory()
        reload()
    }

    func selectPlaceCluster(_ ids: [String]) {
        if Set(placeMemberIDs ?? []) == Set(ids) {
            placeMemberIDs = nil
        } else {
            placeMemberIDs = ids
        }
        browse = .places
        reload()
    }

    func selectSubject(_ id: String) {
        browse = .people
        selectedKind = nil
        selectedDuplicateID = nil
        selectedStoryID = nil
        placeMemberIDs = nil
        shownStory = nil
        stopStory()
        selectedSubjectID = selectedSubjectID == id ? nil : id
        reload()
    }

    func selectDuplicates() {
        browse = .duplicates
        selectedKind = nil
        selectedSubjectID = nil
        selectedStoryID = nil
        placeMemberIDs = nil
        selectedDuplicateID = nil
        shownStory = nil
        stopStory()
        reload()
    }

    func selectDuplicateGroup(_ id: String) {
        browse = .duplicates
        selectedDuplicateID = selectedDuplicateID == id ? nil : id
        reload()
    }

    func play(_ story: HighlightStory) {
        guard !story.assetIDs.isEmpty else { return }
        browse = .highlights
        selectedKind = nil
        selectedSubjectID = nil
        selectedDuplicateID = nil
        placeMemberIDs = nil
        selectedStoryID = story.id
        shownStory = story
        playingStory = story
        playingIndex = 0
        playingStarted = Date()
        reload()
    }

    func advanceStory() {
        guard let story = playingStory else { return }
        if playingIndex + 1 < story.assetIDs.count {
            playingIndex += 1
            playingStarted = Date()
        } else {
            stopStory()
        }
    }

    func rewindStory() {
        guard playingStory != nil else { return }
        if playingIndex > 0 {
            playingIndex -= 1
            playingStarted = Date()
        }
    }

    func stopStory() {
        playingStory = nil
        playingIndex = 0
    }

    func shuffleMemory() {
        guard let database else { return }
        let enabled = sources.filter(\.enabled).map(\.id)
        status = "Choosing a memory…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let assets = (try? database.memoryAssets(sourceIDs: enabled)) ?? []
            let story = HighlightRules.roulette(
                assets: assets,
                count: 12,
                seed: UInt64(Date().timeIntervalSince1970 * 1000),
                now: Date(),
                calendar: .current
            )
            Task { @MainActor in
                guard let self else { return }
                if let story {
                    self.play(story)
                } else {
                    self.status = "Not enough photos for a memory yet"
                }
            }
        }
    }

    func renameSubject(_ cluster: SubjectClusterRecord) {
        guard let database else { return }
        let alert = NSAlert()
        alert.messageText = cluster.kind == .person ? "Name this person" : "Name this pet"
        alert.informativeText = "The name stays on this Mac."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = cluster.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try database.renameSubject(clusterID: cluster.id, name: field.stringValue)
        } catch {
            status = error.localizedDescription
            return
        }
        refreshMemories()
    }

    func mergeSubject(_ cluster: SubjectClusterRecord, into keepingID: String) {
        guard let database, cluster.id != keepingID else { return }
        do {
            try database.mergeSubjects(keeping: keepingID, absorbing: cluster.id)
        } catch {
            status = error.localizedDescription
            return
        }
        selectedSubjectID = keepingID
        browse = .people
        refreshMemories()
    }

    func removeSelectedFromSubject() {
        guard let database, let asset = selectedAsset, let selectedSubjectID else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this photo from the group?"
        alert.informativeText = "The file stays where it is. Stillroom only forgets that it belongs in this group."
        alert.addButton(withTitle: "Remove from Group")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try database.removeSubject(assetID: asset.id, from: selectedSubjectID)
        } catch {
            status = error.localizedDescription
            return
        }
        refreshMemories()
    }

    func asset(id: String) -> Asset? {
        if let asset = assets.first(where: { $0.id == id }) { return asset }
        return try? database?.asset(id: id)
    }

    func displayName(for cluster: SubjectClusterRecord) -> String {
        let trimmed = cluster.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch cluster.kind {
        case .person: return "Unnamed person"
        case .cat: return "Unnamed cat"
        case .dog: return "Unnamed dog"
        }
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
        refreshMemories()
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
        selectedAssets.removeAll { $0.sourceID == source.id }
        if selectedAsset?.sourceID == source.id || selectedAssets.isEmpty {
            selectedAsset = selectedAssets.last
            selectedAssetID = selectedAsset?.id
        }
        restartWatcher()
        refreshMemories()
    }

    func select(asset: Asset) {
        replaceSelection([asset], focused: asset)
    }

    func replaceSelection(_ assets: [Asset], focused: Asset?) {
        selectedAssets = assets
        selectedAsset = focused ?? assets.last
        selectedAssetID = selectedAsset?.id
    }

    func openConvert() {
        if !selectedAssets.isEmpty {
            convertSession.addAssets(selectedAssets)
        }
        presentedTool = .convert
    }

    func openPDF() {
        if !selectedAssets.isEmpty {
            pdfSession.addAssets(selectedAssets)
        }
        presentedTool = .pdf
    }

    func showConvert(_ asset: Asset) {
        let group = selectedAssets.contains(where: { $0.id == asset.id }) ? selectedAssets : [asset]
        convertSession.addAssets(group)
        presentedTool = .convert
    }

    func showPDF(_ asset: Asset) {
        let group = selectedAssets.contains(where: { $0.id == asset.id }) ? selectedAssets : [asset]
        pdfSession.addAssets(group)
        presentedTool = .pdf
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
        recognition?.schedule(includeVideoKeyframes: recognizeVideoText)
        understanding?.schedule()
        refreshMemories()
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

    private func clearPins() {
        placeMemberIDs = nil
        selectedSubjectID = nil
        selectedStoryID = nil
        selectedDuplicateID = nil
        shownStory = nil
        stopStory()
    }

    private func refreshMemories() {
        guard let database else { return }
        memoryGeneration += 1
        let generation = memoryGeneration
        let enabled = sources.filter(\.enabled).map(\.id)
        let service = recognition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let clusters = (try? database.subjectClusters()) ?? []
            let points = (try? database.geoPoints(sourceIDs: enabled)) ?? []
            let groups = DuplicateGrouping.groups((try? database.duplicateCandidates(sourceIDs: enabled)) ?? [])
            var memories = (try? database.memoryAssets(sourceIDs: enabled)) ?? []
            if let vector = service?.queryVector(for: "a plate of food") {
                let embedded = (try? database.embeddingVectors(
                    modelID: ClipModel.id,
                    scope: LibraryQuery(sourceIDs: enabled)
                )) ?? []
                var scores: [String: Double] = [:]
                for item in embedded {
                    let cosine = EmbeddingMath.cosine(vector, item.values)
                    if cosine > 0 { scores[item.id] = cosine }
                }
                for index in memories.indices {
                    memories[index].foodScore = scores[memories[index].id]
                }
            }
            var names: [String: String] = [:]
            for cluster in clusters {
                names[cluster.id] = cluster.name
            }
            let stories = HighlightRules.stories(assets: memories, names: names, now: Date(), calendar: .current)
            Task { @MainActor in
                guard let self, generation == self.memoryGeneration else { return }
                self.subjectClusters = clusters
                self.mapPoints = points
                self.duplicateGroups = groups
                self.stories = stories
                if let selectedSubjectID = self.selectedSubjectID, !clusters.contains(where: { $0.id == selectedSubjectID }) {
                    self.selectedSubjectID = nil
                }
                self.reload()
            }
        }
    }

    private func reload() {
        guard let database else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let plan = SearchPlan.parse(searchText)
        searchPlan = plan
        hoveredTextHitID = nil
        let query = makeQuery()
        let enabled = sources.filter(\.enabled).map(\.id)
        let selectedIDs = selectedAssets.map(\.id)
        let focusedID = selectedAssetID
        let service = recognition
        let browse = browse
        let placeIDs = placeMemberIDs
        let subjectIDs = subjectClusters.first { $0.id == selectedSubjectID }?.assetIDs ?? []
        let story = currentStory()
        let groups = duplicateGroups
        let duplicateID = selectedDuplicateID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let counts = (try? database.libraryCounts(enabledSourceIDs: enabled)) ?? .empty
            let assets: [Asset]
            let blocks: [GridBlock]?
            if plan.isActive {
                if plan.matchesNothing {
                    assets = []
                } else {
                    let vector = service?.queryVector(for: plan.raw)
                    let ranked = (try? database.searchLibrary(plan: plan, scope: query, queryVector: vector)) ?? []
                    assets = ranked.map(\.asset)
                }
                blocks = nil
            } else {
                switch browse {
                case .library:
                    assets = (try? database.fetchAssets(matching: query)) ?? []
                    blocks = nil
                case .places:
                    var geotagged = (try? database.geotaggedAssets(sourceIDs: enabled)) ?? []
                    if let placeIDs {
                        let allowed = Set(placeIDs)
                        geotagged = geotagged.filter { allowed.contains($0.id) }
                    }
                    assets = geotagged
                    blocks = nil
                case .people:
                    let fetched = (try? database.assets(ids: subjectIDs)) ?? []
                    assets = fetched.sorted(by: Self.newestFirst)
                    blocks = nil
                case .highlights:
                    let ids = story?.assetIDs ?? []
                    let ordered = Self.assetsInOrder(ids: ids, database: database)
                    assets = ordered
                    blocks = story.map { [GridBlock(id: $0.id, title: $0.title, assets: ordered)] }
                case .duplicates:
                    let shown = groups.filter { duplicateID == nil || $0.id == duplicateID }
                    let ids = shown.flatMap(\.assetIDs)
                    let fetched = (try? database.assets(ids: Array(Set(ids)))) ?? []
                    let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let built = shown.compactMap { group -> GridBlock? in
                        let members = group.assetIDs.compactMap { byID[$0] }.sorted(by: Self.newestFirst)
                        guard members.count >= 2 else { return nil }
                        let title = group.kind == .exact ? "Exact · \(members.count)" : "Similar · \(members.count)"
                        return GridBlock(id: group.id, title: title, assets: members)
                    }
                    blocks = built
                    assets = built.flatMap(\.assets)
                }
            }
            let refreshed = selectedIDs.compactMap { id in assets.first(where: { $0.id == id }) }
            let focused = refreshed.first { $0.id == focusedID } ?? refreshed.last
            Task { @MainActor in
                guard let self, generation == self.reloadGeneration else { return }
                self.assets = assets
                self.gridBlocks = blocks
                self.matchedCount = blocks?.reduce(0) { $0 + $1.assets.count } ?? assets.count
                self.counts = counts
                self.selectedAssets = refreshed
                self.selectedAsset = focused
                self.selectedAssetID = focused?.id
            }
        }
    }

    private func currentStory() -> HighlightStory? {
        shownStory
    }

    private static func assetsInOrder(ids: [String], database: IndexDatabase) -> [Asset] {
        let fetched = (try? database.assets(ids: ids)) ?? []
        let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = ids.compactMap { byID[$0] }
        if listed.count == fetched.count { return listed }
        return fetched.sorted(by: newestFirst)
    }

    private static func newestFirst(_ lhs: Asset, _ rhs: Asset) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            return lhs.id < rhs.id
        }
    }

    private func makeQuery() -> LibraryQuery {
        let enabled = sources.filter(\.enabled).map(\.id)
        if browse != .library {
            return LibraryQuery(sourceIDs: enabled, mediaKind: nil)
        }
        let sourceIDs: [String]
        if let selectedSourceID {
            sourceIDs = [selectedSourceID]
        } else {
            sourceIDs = enabled
        }
        return LibraryQuery(sourceIDs: sourceIDs, mediaKind: selectedKind)
    }
}

enum LibraryBrowse: String, Equatable {
    case library
    case places
    case people
    case highlights
    case duplicates
}

struct GridBlock: Equatable, Identifiable {
    var id: String
    var title: String
    var assets: [Asset]
}

enum WorkspaceTool: String, Identifiable {
    case convert
    case pdf

    var id: String { rawValue }
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
