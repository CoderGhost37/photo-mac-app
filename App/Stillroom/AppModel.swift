import AppKit
import Foundation
import PhotoIndex
import SwiftUI

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
    var thumbnailSide: Double = StillroomPreferences.thumbnailSide {
        didSet {
            let clamped = min(320, max(80, thumbnailSide))
            if clamped != thumbnailSide {
                thumbnailSide = clamped
                return
            }
            StillroomPreferences.storeThumbnail(clamped)
        }
    }
    var timelineScale: TimelineScale = StillroomPreferences.timelineScale {
        didSet { StillroomPreferences.storeTimeline(timelineScale) }
    }
    var sort: LibrarySort = .newest
    var inspectorVisible = false
    /// Screenshot runs pin light or dark. Nil follows the Mac.
    var forcedColorScheme: ColorScheme?
    var hiddenLockPresented = false
    var hiddenPromptVisible = false
    var mapUsesSatellite = false
    var placeQuery = ""
    var mapFitToken = 0
    private(set) var placeCounts: [String: Int] = [:]
    private(set) var libraryMoments: [Date] = []
    private var inspectorBeforeViewer: Bool?
    private(set) var recentCount = 0
    private(set) var knownPlaces: [String] = []
    private(set) var scanProgress: ScanProgress?
    var searchTokens: [LibrarySearchToken] = []
    var viewerAssetID: String?
    var highlightedSubjectID: String?
    var selectionAnchorID: String?
    var columnEstimate = 4
    var keyboardMoveToken = 0
    let quickLook = QuickLookBridge()
    private var magnifyBaseline: Double?
    var status = "Opening library…"
    var isIndexing = false
    private(set) var machinePause: BackgroundPauseReason?
    var hiddenUnlocked = false
    private(set) var authenticatingHidden = false
    private var hiddenActivity: Date?
    let importSession = DeviceImportSession()

    private let database: IndexDatabase?
    private let indexer: Indexer?
    private let recognition: RecognitionService?
    private let understanding: UnderstandingService?
    let thumbnails: ThumbnailService?
    private let limits: MachineLimits
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
        if hiddenLockPresented { return "Hidden" }
        if isSearching { return "Search" }
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
                return playingStory.kind == .forYou ? "For You" : playingStory.title
            }
            if let shownStory, shownStory.id == selectedStoryID {
                return shownStory.kind == .forYou ? "For You" : shownStory.title
            }
            if let selectedStoryID, let story = stories.first(where: { $0.id == selectedStoryID }) {
                return story.kind == .forYou ? "For You" : story.title
            }
            return "Memories"
        case .duplicates:
            return "Duplicates"
        case .hidden:
            return "Hidden"
        case .favorites:
            return "Favorites"
        case .recents:
            return "Recents"
        case .library:
            var parts: [String] = []
            if let selectedSourceID, let source = sources.first(where: { $0.id == selectedSourceID }) {
                parts.append(source.displayName)
            }
            if let selectedKind {
                parts.append(Format.mediaTitle(selectedKind))
            }
            return parts.isEmpty ? "All Photos" : parts.joined(separator: " · ")
        }
    }

    var librarySubtitle: String {
        if hiddenLockPresented || browse == .hidden || isSearching { return "" }
        if viewerAssetID != nil { return "" }
        switch browse {
        case .places:
            return "\(Format.countPhrase(mapPoints.count, singular: "photo", plural: "photos")) with a location"
        case .people:
            if selectedSubjectID != nil { return "" }
            let people = subjectClusters.filter { $0.kind == .person }.count
            let pets = subjectClusters.count - people
            return "\(Format.countPhrase(people, singular: "person", plural: "people")) · \(Format.countPhrase(pets, singular: "pet", plural: "pets"))"
        case .highlights:
            return shownStory == nil ? "Made from your library" : ""
        case .duplicates:
            let photos = duplicateGroups.reduce(0) { $0 + $1.count }
            return "\(Format.countPhrase(duplicateGroups.count, singular: "group", plural: "groups")) · \(Format.countPhrase(photos, singular: "photo", plural: "photos"))"
        case .library where selectedKind == nil && selectedSourceID == nil:
            return mediaSummary
        case .library, .favorites, .recents, .hidden:
            return Format.countPhrase(matchedCount, singular: "item", plural: "items")
        }
    }

    var mediaSummary: String {
        let photos = (counts.byMediaKind[.photo] ?? 0) + (counts.byMediaKind[.screenshot] ?? 0)
        let videos = (counts.byMediaKind[.video] ?? 0) + (counts.byMediaKind[.screenRecording] ?? 0)
        if photos == 0 && videos == 0 { return "0 items" }
        var parts: [String] = []
        if photos > 0 { parts.append(Format.countPhrase(photos, singular: "photo", plural: "photos")) }
        if videos > 0 { parts.append(Format.countPhrase(videos, singular: "video", plural: "videos")) }
        return parts.joined(separator: " · ")
    }

    var usesLargeTitle: Bool {
        if hiddenLockPresented || isSearching || viewerAssetID != nil { return false }
        if browse == .people, selectedSubjectID != nil { return false }
        return !librarySubtitle.isEmpty
    }

    var showsTimelinePicker: Bool {
        if hiddenLockPresented { return true }
        if isSearching || viewerAssetID != nil { return false }
        switch browse {
        case .library, .favorites, .recents, .hidden:
            return true
        case .people, .places, .highlights, .duplicates:
            return false
        }
    }

    var showsZoom: Bool {
        if hiddenLockPresented { return true }
        if isSearching || viewerAssetID != nil { return false }
        switch browse {
        case .library, .favorites, .recents, .hidden, .duplicates:
            return true
        case .people:
            return selectedSubjectID != nil
        case .places, .highlights:
            return false
        }
    }

    var sidebarSelection: SidebarSelection {
        if hiddenLockPresented { return .hidden }
        switch browse {
        case .favorites: return .favorites
        case .recents: return .recents
        case .places: return .map
        case .people: return .people
        case .highlights:
            return .memories
        case .duplicates: return .duplicates
        case .hidden: return .hidden
        case .library:
            if let selectedKind { return .kind(selectedKind) }
            if let selectedSourceID { return .source(selectedSourceID) }
            return .all
        }
    }

    var footer: LibraryFooter {
        if keepStatus || machinePause != nil {
            return .message(status)
        }
        if isIndexing {
            return .indexing(scanProgress)
        }
        return .current
    }

    var combinedSearchText: String {
        (searchTokens.map(\.value) + [searchText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var searchSuggestions: [LibrarySearchToken] {
        let typed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let needle = typed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let existing = Set(searchTokens.map(\.id))
        var items: [LibrarySearchToken] = []
        func add(_ token: LibrarySearchToken) {
            guard !existing.contains(token.id), !items.contains(token) else { return }
            items.append(token)
        }
        for cluster in subjectClusters {
            let name = cluster.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard folded.contains(needle) else { continue }
            add(LibrarySearchToken(kind: .person, value: name, count: cluster.count))
            if items.count >= 4 { break }
        }
        for place in knownPlaces {
            let folded = place.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard folded.contains(needle) else { continue }
            add(LibrarySearchToken(kind: .place, value: place, count: placeCounts[place]))
            if items.count >= 6 { break }
        }
        let plan = SearchPlan.parse(typed)
        if plan.dateRange != nil || !plan.dateTokens.isEmpty {
            let count = plan.dateRange.map { range in
                libraryMoments.filter { range.contains($0) }.count
            }
            add(LibrarySearchToken(kind: .date, value: typed, count: count))
        }
        add(LibrarySearchToken(kind: .text, value: typed))
        return Array(items.prefix(8))
    }

    var queryToken: String {
        let blocks = gridBlocks?.map(\.id).joined(separator: ",") ?? ""
        let tokens = searchTokens.map(\.id).joined(separator: ",")
        return "\(browse.rawValue)|\(selectedSourceID ?? "*")|\(selectedKind?.rawValue ?? "*")|\(combinedSearchText)|\(tokens)|\(selectedSubjectID ?? "")|\(selectedStoryID ?? "")|\(selectedDuplicateID ?? "")|\(placeMemberIDs?.count ?? -1)|\(blocks)"
    }

    var isSearching: Bool { searchPlan.isActive }

    var smartSearchReady: Bool {
        ClipInstall.isComplete(directory: ClipModel.resolve(
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundle: .main
        ))
    }

    init() {
        let limits = MachineLimits()
        self.limits = limits
        let home = StillroomPreferences.home
        do {
            let database = try IndexDatabase(path: IndexLocation.databaseURL(home: home).path)
            self.database = database
            self.indexer = Indexer(database: database, metadataReader: AppleMetadataReader())
            self.recognition = RecognitionService(database: database, home: home, pauseReason: { limits.current() })
            self.understanding = UnderstandingService(database: database, home: home, pauseReason: { limits.current() })
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
        refreshLimits()
        startLimitTimer()
        do {
            try prepareSources()
        } catch {
            status = error.localizedDescription
        }
        if ScreenshotSession.isEnabled {
            guard let database else { return }
            for index in sources.indices where sources[index].enabled {
                sources[index].enabled = false
                try? database.save(source: sources[index])
            }
            status = "Library is up to date"
            isIndexing = false
            reload()
            return
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
        hiddenLockPresented = false
        hiddenPromptVisible = false
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

    func focusPlaceCluster(_ ids: [String]) {
        placeMemberIDs = ids
        browse = .places
        reload()
    }

    func selectSubject(_ id: String) {
        hiddenLockPresented = false
        hiddenPromptVisible = false
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
        hiddenLockPresented = false
        hiddenPromptVisible = false
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

    func selectHidden() {
        if hiddenUnlocked {
            hiddenLockPresented = false
            hiddenPromptVisible = false
            showHiddenAlbum()
            return
        }
        hiddenLockPresented = true
        hiddenPromptVisible = true
        inspectorVisible = false
    }

    func dismissHiddenPrompt() {
        hiddenPromptVisible = false
    }

    func unlockHidden() {
        guard !authenticatingHidden else { return }
        authenticatingHidden = true
        Task {
            let ok = await HiddenAuthentication.unlock()
            authenticatingHidden = false
            if ok {
                hiddenUnlocked = true
                hiddenLockPresented = false
                hiddenPromptVisible = false
                hiddenActivity = Date()
                showHiddenAlbum()
            } else {
                status = "Hidden album stayed locked."
                hiddenPromptVisible = true
            }
        }
    }

    func noteInactive() {
        guard hiddenUnlocked else { return }
        guard HiddenLock.shouldLock(
            inactive: true,
            authenticating: authenticatingHidden,
            lastActivity: hiddenActivity,
            now: Date()
        ) else { return }
        lockHidden()
    }

    func setHidden(_ hidden: Bool, assets: [Asset]) {
        let targets = assets.isEmpty ? selectedAssets : assets
        guard let database, !targets.isEmpty else { return }
        do {
            try database.setHidden(hidden, assetIDs: targets.map(\.id))
        } catch {
            status = error.localizedDescription
            return
        }
        if hidden {
            status = targets.count == 1 ? "Hidden. The file was not changed." : "Hidden \(targets.count). The files were not changed."
        } else {
            status = "Back in the library. The file was not changed."
        }
        refreshMemories()
    }

    func adoptImportFolder(_ url: URL) {
        guard let database else { return }
        let path = SourceCatalog.normalizedDirectory(url).path
        if sources.contains(where: { $0.rootPath == path }) {
            if let source = sources.first(where: { $0.rootPath == path }) {
                scheduleScan(source)
            }
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
        restartWatcher()
        scheduleScan(source)
        reload()
    }

    func importSignatures() -> Set<String> {
        (try? database?.importSignatures()) ?? []
    }

    func recordDeviceImports(_ records: [(signature: String, relativePath: String)]) {
        guard let database, !records.isEmpty else { return }
        try? database.recordImports(records, at: Date())
    }

    private func showHiddenAlbum() {
        hiddenLockPresented = false
        hiddenPromptVisible = false
        browse = .hidden
        selectedKind = nil
        selectedSourceID = nil
        clearPins()
        hiddenActivity = Date()
        reload()
    }

    private func lockHidden() {
        hiddenUnlocked = false
        hiddenActivity = nil
        hiddenLockPresented = false
        hiddenPromptVisible = false
        guard browse == .hidden else { return }
        browse = .library
        selectedSourceID = nil
        selectedKind = nil
        clearPins()
        status = "Hidden album locked."
        reload()
    }

    func refreshLimits() {
        let snapshot = PowerMonitor.snapshot()
        let previous = machinePause
        limits.update(snapshot)
        machinePause = limits.current()
        if let machinePause {
            status = BackgroundPause.message(machinePause)
        } else if previous != nil, !isIndexing, !keepStatus {
            status = "Library is up to date"
        }
        if hiddenUnlocked, HiddenLock.shouldLock(
            inactive: false,
            authenticating: authenticatingHidden,
            lastActivity: hiddenActivity,
            now: Date()
        ) {
            lockHidden()
        }
    }

    private func startLimitTimer() {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLimits()
            }
        }
    }

    func selectDuplicateGroup(_ id: String) {
        browse = .duplicates
        selectedDuplicateID = selectedDuplicateID == id ? nil : id
        reload()
    }

    func play(_ story: HighlightStory) {
        guard !story.assetIDs.isEmpty else { return }
        hiddenLockPresented = false
        hiddenPromptVisible = false
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
        if browse == .hidden {
            hiddenActivity = Date()
        }
    }

    func openConvert() {
        if !selectedAssets.isEmpty {
            convertSession.addAssets(selectedAssets)
        }
        presentedTool = .convert
    }

    func openImport() {
        presentedTool = .deviceImport
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
        let home = StillroomPreferences.home
        let capture = ScreenshotLocation.current(home: home)
        _ = try database.synchronizeBuiltinSources(homeDirectory: home, captureDirectory: capture)
        let discovered = CaptureToolLocator.discover(home: home)
        let roots = (try database.sources()).compactMap(\.rootPath)
        let tools = CaptureToolPreferences.offering(discovered, existingRoots: roots).map(CaptureToolPreferences.source(for:))
        try database.synchronizeCaptureTools(tools)
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
        let relay = StatusRelay(
            { [weak self] text in
                Task { @MainActor in
                    self?.status = text
                }
            },
            progress: { [weak self] completed, total in
                Task { @MainActor in
                    self?.scanProgress = ScanProgress(completed: completed, total: total)
                }
            }
        )
        let limits = self.limits
        scanQueue.async { [weak self] in
            while let reason = limits.current() {
                relay.send(BackgroundPause.message(reason))
                Thread.sleep(forTimeInterval: 1)
            }
            let group = DispatchGroup()
            group.enter()
            var outcome: Result<ScanStats, Error> = .success(.zero)
            Task {
                do {
                    if source.kind == .photosLibrary {
                        outcome = .success(try await Self.scanPhotos(source: source, indexer: indexer, database: database))
                    } else {
                        let stats = try await indexer.scan(
                            source,
                            onProgress: { examined, total in
                                relay.send("Indexing \(name) · \(examined) of \(total)")
                                relay.sendProgress(completed: examined, total: total)
                            },
                            onPause: { reason in
                                relay.send(BackgroundPause.message(reason))
                            },
                            pauseReason: { limits.current() }
                        )
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
        if !isIndexing {
            scanProgress = nil
        }
        if !isIndexing, launchError == nil, !keepStatus {
            status = "Library is up to date"
        }
    }

    private func clearPins() {
        hiddenLockPresented = false
        hiddenPromptVisible = false
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
            var countedPlaces: [String: Int] = [:]
            var moments: [Date] = []
            for asset in memories {
                if let date = asset.createdAt {
                    moments.append(date)
                }
                let trimmed = asset.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    countedPlaces[trimmed, default: 0] += 1
                }
            }
            let placeNames = countedPlaces.keys.sorted()
            Task { @MainActor in
                guard let self, generation == self.memoryGeneration else { return }
                self.subjectClusters = clusters
                self.mapPoints = points
                self.duplicateGroups = groups
                self.stories = stories
                self.knownPlaces = placeNames
                self.placeCounts = countedPlaces
                self.libraryMoments = moments
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
        let plan = SearchPlan.parse(combinedSearchText)
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
        let recentSince = RecentsWindow.start(now: Date(), calendar: .current)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let counts = (try? database.libraryCounts(enabledSourceIDs: enabled)) ?? .empty
            let recentCount = enabled.isEmpty
                ? 0
                : ((try? database.countAssets(matching: LibraryQuery(sourceIDs: enabled, createdAfter: recentSince))) ?? 0)
            var assets: [Asset]
            var blocks: [GridBlock]?
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
                case .library, .favorites, .recents:
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
                case .hidden:
                    assets = (try? database.fetchAssets(matching: query)) ?? []
                    blocks = nil
                }
            }
            if browse != .hidden {
                assets = assets.filter { !$0.isHidden }
                if blocks != nil {
                    blocks = blocks?.compactMap { block in
                        let kept = block.assets.filter { !$0.isHidden }
                        guard !kept.isEmpty else { return nil }
                        if browse == .duplicates, kept.count < 2 { return nil }
                        return GridBlock(id: block.id, title: block.title, assets: kept)
                    }
                    assets = blocks?.flatMap(\.assets) ?? assets
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
                self.recentCount = recentCount
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
        if browse == .hidden {
            return LibraryQuery(sourceIDs: sources.map(\.id), mediaKind: nil, visibility: .hidden)
        }
        let enabled = sources.filter(\.enabled).map(\.id)
        switch browse {
        case .favorites:
            return LibraryQuery(sourceIDs: enabled, favoritesOnly: true)
        case .recents:
            return LibraryQuery(sourceIDs: enabled, createdAfter: RecentsWindow.start(now: Date(), calendar: .current))
        case .library:
            let sourceIDs = selectedSourceID.map { [$0] } ?? enabled
            return LibraryQuery(sourceIDs: sourceIDs, mediaKind: selectedKind)
        case .places, .people, .highlights, .duplicates, .hidden:
            return LibraryQuery(sourceIDs: enabled, mediaKind: nil)
        }
    }

    func selectFavorites() {
        browse = .favorites
        selectedSourceID = nil
        selectedKind = nil
        clearPins()
        reload()
    }

    func selectRecents() {
        browse = .recents
        selectedSourceID = nil
        selectedKind = nil
        clearPins()
        reload()
    }

    func selectMemories() {
        hiddenLockPresented = false
        hiddenPromptVisible = false
        browse = .highlights
        selectedKind = nil
        selectedSourceID = nil
        clearPins()
        reload()
    }

    func selectPeople() {
        hiddenLockPresented = false
        hiddenPromptVisible = false
        browse = .people
        selectedKind = nil
        selectedDuplicateID = nil
        selectedStoryID = nil
        placeMemberIDs = nil
        shownStory = nil
        stopStory()
        selectedSubjectID = nil
        reload()
    }

    func openSubject(_ id: String) {
        hiddenLockPresented = false
        hiddenPromptVisible = false
        browse = .people
        selectedKind = nil
        selectedDuplicateID = nil
        selectedStoryID = nil
        placeMemberIDs = nil
        shownStory = nil
        stopStory()
        selectedSubjectID = id
        reload()
    }

    func showStory(_ story: HighlightStory) {
        guard !story.assetIDs.isEmpty else { return }
        hiddenLockPresented = false
        hiddenPromptVisible = false
        browse = .highlights
        selectedKind = nil
        selectedSubjectID = nil
        selectedDuplicateID = nil
        placeMemberIDs = nil
        selectedStoryID = story.id
        shownStory = story
        stopStory()
        reload()
    }

    func applySidebar(_ selection: SidebarSelection) {
        switch selection {
        case .all:
            selectAll()
        case .favorites:
            selectFavorites()
        case .recents:
            selectRecents()
        case .kind(let kind):
            browse = .library
            clearPins()
            selectedSourceID = nil
            selectedKind = kind
            reload()
        case .map:
            selectPlaces()
        case .people:
            selectPeople()
        case .memories:
            selectMemories()
        case .duplicates:
            selectDuplicates()
        case .hidden:
            selectHidden()
        case .source(let id):
            browse = .library
            clearPins()
            selectedKind = nil
            selectedSourceID = id
            reload()
        }
    }

    func addSearchToken(_ token: LibrarySearchToken) {
        if !searchTokens.contains(token) {
            searchTokens.append(token)
        }
        searchText = ""
    }

    func rescan() {
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else {
            status = "Turn on a source to rescan."
            keepStatus = true
            return
        }
        keepStatus = false
        for source in enabled {
            scheduleScan(source)
        }
    }

    func adjustZoom(by delta: Double) {
        thumbnailSide = min(320, max(80, thumbnailSide + delta))
    }

    func applyMagnification(_ magnification: CGFloat) {
        if magnifyBaseline == nil {
            magnifyBaseline = thumbnailSide
        }
        let next = (magnifyBaseline ?? thumbnailSide) * Double(magnification)
        thumbnailSide = min(320, max(80, next))
    }

    func endMagnification() {
        magnifyBaseline = nil
    }

    func updateColumnEstimate(width: CGFloat) {
        let side = CGFloat(thumbnailSide)
        guard side > 0, width > 0 else { return }
        let spacing = Metrics.gridSpacing
        columnEstimate = max(1, Int((width + spacing) / (side + spacing)))
    }

    func visibleSections() -> [TimelineSection] {
        if isSearching {
            return assets.isEmpty ? [] : [TimelineSection(id: "results", title: "", place: nil, assets: assets)]
        }
        if browse == .duplicates, let gridBlocks {
            return gridBlocks.map { TimelineSection(id: $0.id, title: $0.title, place: nil, assets: $0.assets) }
        }
        if browse == .highlights, let gridBlocks {
            return gridBlocks.map { TimelineSection(id: $0.id, title: "", place: nil, assets: $0.assets) }
        }
        if browse == .people, selectedSubjectID == nil {
            return []
        }
        return TimelineGrouping.sections(assets: assets, scale: timelineScale, sort: sort)
    }

    func flatAssets() -> [Asset] {
        visibleSections().flatMap(\.assets)
    }

    func click(_ asset: Asset) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            toggleSelection(asset)
        } else if flags.contains(.shift) {
            extendSelection(to: asset)
        } else {
            replaceSelection([asset], focused: asset)
            selectionAnchorID = asset.id
        }
    }

    func toggleSelection(_ asset: Asset) {
        if selectedAssets.contains(where: { $0.id == asset.id }) {
            let remaining = selectedAssets.filter { $0.id != asset.id }
            replaceSelection(remaining, focused: remaining.last)
        } else {
            replaceSelection(selectedAssets + [asset], focused: asset)
            if selectionAnchorID == nil { selectionAnchorID = asset.id }
        }
    }

    func extendSelection(to asset: Asset) {
        let flat = flatAssets()
        guard let end = flat.firstIndex(where: { $0.id == asset.id }) else {
            replaceSelection([asset], focused: asset)
            return
        }
        let startID = selectionAnchorID ?? selectedAssetID
        let start = startID.flatMap { id in flat.firstIndex(where: { $0.id == id }) } ?? end
        let lower = min(start, end)
        let upper = max(start, end)
        replaceSelection(Array(flat[lower...upper]), focused: asset)
    }

    func moveSelection(delta: Int) {
        let flat = flatAssets()
        guard !flat.isEmpty else { return }
        let current = selectedAssetID.flatMap { id in flat.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(0, current + delta), flat.count - 1)
        let asset = flat[nextIndex]
        replaceSelection([asset], focused: asset)
        selectionAnchorID = asset.id
        keyboardMoveToken += 1
        if viewerAssetID != nil {
            viewerAssetID = asset.id
        }
    }

    func openViewer(_ asset: Asset) {
        if !selectedAssets.contains(where: { $0.id == asset.id }) {
            replaceSelection([asset], focused: asset)
        }
        if inspectorBeforeViewer == nil {
            inspectorBeforeViewer = inspectorVisible
        }
        viewerAssetID = asset.id
        inspectorVisible = true
    }

    func closeViewer() {
        viewerAssetID = nil
        if let previous = inspectorBeforeViewer {
            inspectorVisible = previous
            inspectorBeforeViewer = nil
        }
    }

    func showInfo(_ asset: Asset) {
        if !selectedAssets.contains(where: { $0.id == asset.id }) {
            replaceSelection([asset], focused: asset)
        } else {
            selectedAsset = asset
            selectedAssetID = asset.id
        }
        inspectorVisible = true
    }

    func share(_ asset: Asset) {
        guard let path = asset.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let picker = NSSharingServicePicker(items: [url])
        guard let view = NSApp.keyWindow?.contentView else { return }
        let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func quickLookSelection() {
        let targets = selectedAssets.isEmpty ? (selectedAsset.map { [$0] } ?? []) : selectedAssets
        let urls = targets.compactMap(\.filePath).map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        quickLook.present(urls)
    }

    func setFavorite(_ favorite: Bool, assets: [Asset]) {
        let targets = assets.isEmpty ? selectedAssets : assets
        guard let database, !targets.isEmpty else { return }
        do {
            try database.setFavorite(favorite, assetIDs: targets.map(\.id))
        } catch {
            status = error.localizedDescription
            return
        }
        let ids = Set(targets.map(\.id))
        var delta = 0
        for index in self.assets.indices where ids.contains(self.assets[index].id) {
            if self.assets[index].isFavorite != favorite {
                delta += favorite ? 1 : -1
            }
            self.assets[index].isFavorite = favorite
        }
        for asset in targets where !self.assets.contains(where: { $0.id == asset.id }) && asset.isFavorite != favorite {
            delta += favorite ? 1 : -1
        }
        var nextCounts = counts
        nextCounts.favoriteCount = max(0, counts.favoriteCount + delta)
        counts = nextCounts
        gridBlocks = gridBlocks?.map { block in
            var copy = block
            copy.assets = block.assets.map { asset in
                guard ids.contains(asset.id) else { return asset }
                var next = asset
                next.isFavorite = favorite
                return next
            }
            return copy
        }
        if var selected = selectedAsset, ids.contains(selected.id) {
            selected.isFavorite = favorite
            selectedAsset = selected
        }
        selectedAssets = selectedAssets.map { asset in
            guard ids.contains(asset.id) else { return asset }
            var copy = asset
            copy.isFavorite = favorite
            return copy
        }
        if browse == .favorites, !favorite {
            self.assets.removeAll { ids.contains($0.id) }
            matchedCount = gridBlocks?.reduce(0) { $0 + $1.assets.count } ?? self.assets.count
            selectedAssets.removeAll { ids.contains($0.id) }
            if let current = selectedAsset, ids.contains(current.id) {
                selectedAsset = selectedAssets.last
                selectedAssetID = selectedAsset?.id
            }
        }
    }

    func sceneLabels(for asset: Asset) -> [String] {
        (try? database?.sceneLabels(assetID: asset.id)) ?? []
    }

    func people(in asset: Asset) -> [SubjectClusterRecord] {
        subjectClusters.filter { $0.assetIDs.contains(asset.id) }
    }

    func installScreenshotLibrary() async {
        guard let database else { return }
        let folder = StillroomPreferences.home.appendingPathComponent("Pictures/Fixture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let specs: [(String, NSColor, NSSize, Date, String?)] = ScreenshotSession.fixtures(now: Date())
            var firstData: Data?
            var firstDate: Date?
            for spec in specs {
                let url = folder.appendingPathComponent(spec.0)
                if let data = ScreenshotSession.jpeg(color: spec.1, size: spec.2) {
                    if firstData == nil {
                        firstData = data
                        firstDate = spec.3
                    }
                    try data.write(to: url)
                    try FileManager.default.setAttributes(
                        [.creationDate: spec.3, .modificationDate: spec.3],
                        ofItemAtPath: url.path
                    )
                }
            }
            if let firstData, let firstDate {
                let copy = folder.appendingPathComponent("goa-00-copy.jpg")
                try firstData.write(to: copy)
                try FileManager.default.setAttributes(
                    [.creationDate: firstDate, .modificationDate: firstDate],
                    ofItemAtPath: copy.path
                )
            }
        } catch {
            status = error.localizedDescription
            return
        }
        adoptImportFolder(folder)
        for _ in 0..<80 {
            if assets.count >= 8 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let indexed = assets
        guard !indexed.isEmpty else { return }
        var updates: [Asset] = []
        for (offset, asset) in indexed.enumerated() {
            var copy = asset
            if offset < 6 {
                copy.placeName = "Kushavati, Goa"
                copy.latitude = 15.49
                copy.longitude = 73.76
            } else if offset < 9 {
                copy.placeName = "Panaji"
                copy.latitude = 15.49
                copy.longitude = 73.83
            }
            if offset == 0 {
                copy.cameraMake = "Canon"
                copy.cameraModel = "EOS R5"
                copy.lensModel = "RF 24-70mm F2.8"
                copy.iso = 200
                copy.aperture = 2.8
                copy.focalLength = 35
            }
            updates.append(copy)
        }
        try? database.applyChanges(inserted: [], updated: updates, deletedIDs: [])
        let favoriteIDs = updates.prefix(3).map(\.id)
        try? database.setFavorite(true, assetIDs: Array(favoriteIDs))
        if let hero = updates.first {
            let box = NormalizedBox(x: 0.25, y: 0.2, width: 0.4, height: 0.45)
            try? database.replaceSubjects(
                assetID: hero.id,
                contentToken: "screenshot",
                subjects: [
                    StoredSubject(id: "shot-person", assetID: hero.id, kind: .person, box: box, confidence: 0.9, vector: [1, 0, 0, 0])
                ],
                labels: [SceneLabel(label: "landscape", confidence: 0.8), SceneLabel(label: "coast", confidence: 0.6)],
                imageVector: [1, 0, 0, 0]
            )
            try? database.replaceTextHits(
                assetID: hero.id,
                contentToken: "screenshot-text",
                observations: [TextObservation(text: "Kushavati", box: NormalizedBox(x: 0.1, y: 0.7, width: 0.4, height: 0.1), confidence: 0.9)]
            )
        }
        if updates.count > 1 {
            let second = updates[1]
            try? database.replaceSubjects(
                assetID: second.id,
                contentToken: "screenshot-2",
                subjects: [
                    StoredSubject(
                        id: "shot-person-2",
                        assetID: second.id,
                        kind: .person,
                        box: NormalizedBox(x: 0.3, y: 0.25, width: 0.35, height: 0.4),
                        confidence: 0.8,
                        vector: [0, 1, 0, 0]
                    )
                ],
                labels: [],
                imageVector: [0, 1, 0, 0]
            )
        }
        if updates.count > 2 {
            let third = updates[2]
            try? database.replaceSubjects(
                assetID: third.id,
                contentToken: "screenshot-3",
                subjects: [
                    StoredSubject(
                        id: "shot-dog",
                        assetID: third.id,
                        kind: .dog,
                        box: NormalizedBox(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
                        confidence: 0.85,
                        vector: [0, 0, 1, 0]
                    )
                ],
                labels: [SceneLabel(label: "dog", confidence: 0.9)],
                imageVector: [0, 0, 1, 0]
            )
        }
        try? database.assignNewSubjects(makeID: { UUID().uuidString })
        if let clusters = try? database.subjectClusters(),
           let named = clusters.first(where: { $0.assetIDs.contains(updates[0].id) && $0.kind == .person }) {
            try? database.renameSubject(clusterID: named.id, name: "Asha")
        }
        refreshMemories()
        reload()
        for _ in 0..<40 {
            if subjectClusters.count >= 2, assets.contains(where: { $0.placeName != nil }) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await waitUntilSettled()
    }

    func waitUntilSettled() async {
        var last = reloadGeneration
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if reloadGeneration == last, !isIndexing {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if reloadGeneration == last { return }
            }
            last = reloadGeneration
        }
    }
}

enum LibraryBrowse: String, Equatable {
    case library
    case favorites
    case recents
    case places
    case people
    case highlights
    case duplicates
    case hidden
}

enum SidebarSelection: Hashable {
    case all
    case favorites
    case recents
    case kind(MediaKind)
    case map
    case people
    case memories
    case duplicates
    case hidden
    case source(String)
}

struct LibrarySearchToken: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case person
        case place
        case date
        case text
    }

    var kind: Kind
    var value: String
    var count: Int? = nil
    var id: String { "\(kind.rawValue)|\(value)" }

    var symbol: String {
        switch kind {
        case .person: return "person"
        case .place: return "mappin.and.ellipse"
        case .date: return "calendar"
        case .text: return "text.quote"
        }
    }

    var suggestionTitle: String {
        switch kind {
        case .person: return "Person · \(value)"
        case .place: return "Place · \(value)"
        case .date: return "Date · \(value)"
        case .text: return "Text · \(value)"
        }
    }
}

struct ScanProgress: Equatable {
    var completed: Int
    var total: Int
}

enum LibraryFooter: Equatable {
    case current
    case indexing(ScanProgress?)
    case message(String)
}

enum StillroomPreferences {
    static var home: URL {
        if let raw = ProcessInfo.processInfo.environment["STILLROOM_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static let thumbnailKey = "Stillroom.thumbnailSide"
    static let timelineKey = "Stillroom.timelineScale"

    static var thumbnailSide: Double {
        let stored = UserDefaults.standard.double(forKey: thumbnailKey)
        if stored < 80 { return 210 }
        return min(320, max(80, stored))
    }

    static func storeThumbnail(_ value: Double) {
        UserDefaults.standard.set(min(320, max(80, value)), forKey: thumbnailKey)
    }

    static var timelineScale: TimelineScale {
        let raw = UserDefaults.standard.string(forKey: timelineKey) ?? ""
        return TimelineScale(rawValue: raw) ?? .days
    }

    static func storeTimeline(_ scale: TimelineScale) {
        UserDefaults.standard.set(scale.rawValue, forKey: timelineKey)
    }
}

struct GridBlock: Equatable, Identifiable {
    var id: String
    var title: String
    var assets: [Asset]
}

enum WorkspaceTool: String, Identifiable {
    case convert
    case pdf
    case deviceImport

    var id: String { rawValue }
}

private final class StatusRelay: @unchecked Sendable {
    private let handler: (String) -> Void
    private let progress: (Int, Int) -> Void

    init(
        _ handler: @escaping (String) -> Void,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.handler = handler
        self.progress = progress
    }

    func send(_ text: String) {
        handler(text)
    }

    func sendProgress(completed: Int, total: Int) {
        progress(completed, total)
    }
}
