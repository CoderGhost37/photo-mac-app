import AppKit
import PhotoIndex
import SwiftUI
#if canImport(QuickLookUI)
import QuickLookUI
#else
import Quartz
#endif

struct GridView: View {
    var model: AppModel
    var namespace: Namespace.ID
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.browse == .places, !model.isSearching, !model.mapPoints.isEmpty {
                placesBanner
            }
            if model.browse == .duplicates, !model.isSearching {
                Text("View only. Nothing is deleted. Use Show in Finder to see a file on disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.moveSelection(delta: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(delta: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(delta: -model.columnEstimate); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(delta: model.columnEstimate); return .handled }
        .onKeyPress(.space) {
            model.quickLookSelection()
            return .handled
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.browse == .people, model.selectedSubjectID == nil, !model.isSearching {
            peopleGrid
        } else if model.matchedCount == 0 {
            emptyState
        } else {
            photoScroll
        }
    }

    private var placesBanner: some View {
        VStack(spacing: 0) {
            PlacesMapView(points: model.mapPoints) { ids in
                model.selectPlaceCluster(ids)
            }
            .frame(height: 280)
            if model.placeMemberIDs != nil {
                HStack {
                    Text("Photos in the selected place")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show every place") { model.selectPlaces() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    private var photoScroll: some View {
        let sections = model.visibleSections()
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if let story = coverStory {
                        memoryCover(story)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    }
                    if sections.count == 1, sections[0].title.isEmpty {
                        photoGrid(sections[0].assets)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    photoGrid(section.assets)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 4)
                                } header: {
                                    if !section.title.isEmpty {
                                        sectionHeader(section)
                                    }
                                }
                            }
                        }
                    }
                }
                .onChange(of: model.keyboardMoveToken) { _, _ in
                    if let id = model.selectedAssetID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onAppear { model.updateColumnEstimate(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, width in
                model.updateColumnEstimate(width: width)
            }
            .onChange(of: model.thumbnailSide) { _, _ in
                model.updateColumnEstimate(width: geo.size.width)
            }
            .gesture(zoomGesture)
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.applyMagnification(value.magnification)
            }
            .onEnded { _ in
                model.endMagnification()
            }
    }

    private var coverStory: HighlightStory? {
        guard model.browse == .highlights, !model.isSearching else { return nil }
        return model.shownStory
    }

    private func memoryCover(_ story: HighlightStory) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(story.kind == .forYou ? "For You" : story.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(Format.count(story.count)) items")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.86))
            }
            Spacer(minLength: 12)
            Button {
                model.shuffleMemory()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .help("Shuffle a memory")
            Button {
                model.play(story)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(Palette.favoriteColor)
            .help("Play this memory")
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .bottomLeading)
        .background(Palette.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title)
                .font(.title3.weight(.semibold))
            if let place = section.place, !place.isEmpty {
                Text("· \(place)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func photoGrid(_ assets: [Asset]) -> some View {
        let thumb = CGFloat(model.thumbnailSide)
        let columns = [GridItem(.adaptive(minimum: thumb, maximum: thumb * 1.4), spacing: 2)]
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets) { asset in
                PhotoTile(
                    model: model,
                    asset: asset,
                    side: thumb,
                    namespace: namespace,
                    selected: model.selectedAssets.contains(where: { $0.id == asset.id })
                )
                .id(asset.id)
            }
        }
    }

    private var peopleGrid: some View {
        Group {
            if model.subjectClusters.isEmpty {
                ContentUnavailableView(
                    "People & Pets",
                    systemImage: "person.2",
                    description: Text("Faces and pets are grouped on this Mac after photos are read. Nothing is uploaded.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)], spacing: 22) {
                        ForEach(sortedClusters) { cluster in
                            personCard(cluster)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private var sortedClusters: [SubjectClusterRecord] {
        model.subjectClusters.sorted { lhs, rhs in
            let leftKind = kindOrder(lhs.kind)
            let rightKind = kindOrder(rhs.kind)
            if leftKind != rightKind { return leftKind < rightKind }
            let leftNamed = !lhs.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let rightNamed = !rhs.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if leftNamed != rightNamed { return leftNamed && !rightNamed }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return model.displayName(for: lhs).localizedCaseInsensitiveCompare(model.displayName(for: rhs)) == .orderedAscending
        }
    }

    private func kindOrder(_ kind: SubjectKind) -> Int {
        switch kind {
        case .person: return 0
        case .cat: return 1
        case .dog: return 2
        }
    }

    private func personCard(_ cluster: SubjectClusterRecord) -> some View {
        let named = !cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selected = model.highlightedSubjectID == cluster.id
        return VStack(spacing: 8) {
            FaceBubble(
                model: model,
                assetID: cluster.coverAssetID,
                box: cluster.coverBox,
                symbol: cluster.kind == .person ? "person.crop.circle" : "pawprint"
            )
            .frame(width: 96, height: 96)
            .overlay {
                if selected {
                    Circle().strokeBorder(Palette.brandGradient, lineWidth: 3)
                }
            }
            .onTapGesture(count: 2) { model.openSubject(cluster.id) }
            .onTapGesture(count: 1) { model.highlightedSubjectID = cluster.id }
            Button(named ? model.displayName(for: cluster) : "Add Name") {
                if named {
                    model.openSubject(cluster.id)
                } else {
                    model.renameSubject(cluster)
                }
            }
            .buttonStyle(.plain)
            .font(.body)
            .foregroundStyle(named ? .primary : .secondary)
            .lineLimit(1)
            Text(Format.count(cluster.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            Button("Rename…") { model.renameSubject(cluster) }
            let others = sortedClusters.filter { $0.kind == cluster.kind && $0.id != cluster.id }
            if !others.isEmpty {
                Menu("Merge into") {
                    ForEach(Array(others.prefix(12))) { other in
                        Button(model.displayName(for: other)) {
                            model.mergeSubject(cluster, into: other.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            ContentUnavailableView.search(text: model.combinedSearchText)
        } else if model.isIndexing, model.counts.enabledTotal == 0 {
            ContentUnavailableView {
                ProgressView()
                    .controlSize(.large)
                Text("Indexing Library")
                    .font(.title2.weight(.semibold))
            } description: {
                Text(model.status)
            }
        } else if model.counts.enabledTotal == 0, model.browse == .library {
            ContentUnavailableView {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 52))
                        .foregroundStyle(Palette.brandGradient)
                    Text("No Photos Yet")
                        .font(.title2.weight(.semibold))
                }
            } description: {
                Text("Turn on Screenshots, Downloads, or the Photos library, or add a folder. Stillroom reads files where they are.")
            } actions: {
                Button("Add Folder…") { model.addFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyDetail))
        }
    }

    private var emptySymbol: String {
        switch model.browse {
        case .places: return "map"
        case .people: return "person.2"
        case .highlights: return "sparkles"
        case .duplicates: return "square.on.square"
        case .hidden: return "lock"
        case .favorites: return "heart"
        case .recents: return "clock"
        case .library: return "photo.on.rectangle"
        }
    }

    private var emptyTitle: String {
        switch model.browse {
        case .places: return "No places yet"
        case .people: return model.selectedSubjectID == nil ? "People & Pets" : "Nothing in this group"
        case .highlights: return "Memories"
        case .duplicates: return "No duplicates"
        case .hidden: return "Nothing is hidden"
        case .favorites: return "No Favorites"
        case .recents: return "No Recent Items"
        case .library: return "Nothing in this view"
        }
    }

    private var emptyDetail: String {
        switch model.browse {
        case .places:
            return "Geotagged photos show up on the map. Stillroom reads coordinates already in the file and asks Apple for a place name."
        case .people:
            return "This group is empty. The photos are still in the library."
        case .highlights:
            return "Shuffle a memory, or choose one in the sidebar. Playback stays on this Mac."
        case .duplicates:
            return "Exact copies share a file hash. Similar photos appear after this Mac reads them. Nothing is deleted."
        case .hidden:
            return "Hide a photo from the menu on a thumbnail. The file stays where it is."
        case .favorites:
            return "Hover a photo and click the heart. The file is not changed."
        case .recents:
            return "Photos from the last 30 days show up here."
        case .library:
            return "Try another media type or source. The files themselves are unchanged."
        }
    }
}

private struct PhotoTile: View {
    var model: AppModel
    var asset: Asset
    var side: Double
    var namespace: Namespace.ID
    var selected: Bool
    @State private var image: NSImage?
    @State private var revealed = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(revealed ? 1 : 0)
            } else {
                Image(systemName: Format.mediaSymbol(asset.mediaKind))
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if hovering || asset.isFavorite {
                Button {
                    model.setFavorite(!asset.isFavorite, assets: [asset])
                } label: {
                    Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(asset.isFavorite ? Palette.favoriteColor : Color.white)
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help(asset.isFavorite ? "Remove from Favorites" : "Favorite")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = asset.duration, duration > 0,
               asset.mediaKind == .video || asset.mediaKind == .screenRecording {
                Text(Format.duration(duration))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.openViewer(asset) }
        .onTapGesture(count: 1) { model.click(asset) }
        .onDrag {
            guard let path = asset.filePath else { return NSItemProvider() }
            return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
        }
        .contextMenu { tileMenu }
        .matchedGeometryEffect(id: model.viewerAssetID == asset.id ? asset.id : "idle-\(asset.id)", in: namespace)
        .task(id: "\(asset.id)|\(asset.contentHash ?? "")|\(Int(side))") {
            revealed = false
            let loaded = await model.thumbnails?.image(for: asset, pointSize: CGFloat(side), scale: 2, quality: .grid)
            guard !Task.isCancelled else { return }
            image = loaded
            withAnimation(.easeIn(duration: 0.15)) {
                revealed = true
            }
        }
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accessibilityName: String {
        if let path = asset.filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return Format.mediaTitle(asset.mediaKind)
    }

    @ViewBuilder
    private var tileMenu: some View {
        Button(asset.isFavorite ? "Unfavorite" : "Favorite") {
            model.setFavorite(!asset.isFavorite, assets: [asset])
        }
        Button("Get Info") { model.showInfo(asset) }
        if asset.filePath != nil {
            Button("Share") { model.share(asset) }
            Button("Show in Finder") { model.reveal(asset) }
        } else {
            Button("Open Photos") { model.openPhotosApp() }
        }
        Button("Convert") { model.showConvert(asset) }
        Divider()
        Button("Open") { model.open(asset) }
        Button("Add to PDF…") { model.showPDF(asset) }
        Button(asset.isHidden ? "Unhide" : "Hide") {
            model.setHidden(!asset.isHidden, assets: [asset])
        }
    }
}

struct PhotoViewer: View {
    var model: AppModel
    var asset: Asset
    var namespace: Namespace.ID
    @State private var image: NSImage?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .onTapGesture { model.closeViewer() }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(36)
                    .matchedGeometryEffect(id: asset.id, in: namespace)
                    .allowsHitTesting(false)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            VStack {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        model.open(asset)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .labelStyle(.iconOnly)
                    .help("Open")
                    Button {
                        model.closeViewer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
                .padding(16)
                Spacer()
            }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onExitCommand { model.closeViewer() }
        .onKeyPress(.escape) {
            model.closeViewer()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.moveSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.moveSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.space) {
            model.quickLookSelection()
            return .handled
        }
        .task(id: asset.id) {
            image = nil
            let loaded = await model.thumbnails?.image(for: asset, pointSize: 1400, scale: 2, quality: .preview)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }

    private var title: String {
        if let path = asset.filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return Format.mediaTitle(asset.mediaKind)
    }
}

@MainActor
final class QuickLookBridge: NSObject {
    weak var host: QuickLookHostView?

    func present(_ urls: [URL]) {
        host?.urls = urls
        host?.openPanel()
    }
}

struct QuickLookHost: NSViewRepresentable {
    var bridge: QuickLookBridge

    func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        bridge.host = view
        return view
    }

    func updateNSView(_ view: QuickLookHostView, context: Context) {
        bridge.host = view
    }
}

final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []

    func openPanel() {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
