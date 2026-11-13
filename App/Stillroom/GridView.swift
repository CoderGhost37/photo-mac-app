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
    @State private var resultScope: ResultScope = .all
    @State private var resultOrder: ResultOrder = .relevance

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvasColor)
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
        if model.hiddenLockPresented {
            hiddenLock
        } else if model.browse == .people, model.selectedSubjectID == nil, !model.isSearching {
            peoplePage
        } else if model.browse == .highlights, model.shownStory == nil, !model.isSearching {
            memoriesPage
        } else if model.browse == .duplicates, !model.isSearching {
            duplicatesPage
        } else if model.browse == .places, !model.isSearching {
            placesPage
        } else if model.isSearching {
            if model.matchedCount == 0 {
                ContentUnavailableView.search(text: model.combinedSearchText)
            } else {
                searchResults
            }
        } else if model.matchedCount == 0 {
            emptyState
        } else {
            libraryGrid
        }
    }

    private var libraryGrid: some View {
        VStack(spacing: 0) {
            if let cluster = openPerson {
                personHeader(cluster)
            }
            photoScroll(captions: false)
            if model.browse != .hidden {
                Text(Format.countPhrase(model.matchedCount, singular: "item", plural: "items"))
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }

    private var openPerson: SubjectClusterRecord? {
        guard model.browse == .people, let id = model.selectedSubjectID else { return nil }
        return model.subjectClusters.first { $0.id == id }
    }

    private func photoScroll(captions: Bool) -> some View {
        let sections = model.visibleSections()
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if sections.count == 1, sections[0].title.isEmpty {
                        photoGrid(sections[0].assets, width: gridWidth(geo.size.width), captions: captions)
                            .padding(.horizontal, Metrics.pageInset)
                            .padding(.vertical, 12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    photoGrid(section.assets, width: gridWidth(geo.size.width), captions: captions)
                                        .padding(.horizontal, Metrics.pageInset)
                                        .padding(.bottom, 8)
                                } header: {
                                    if !sectionTitle(section).isEmpty {
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
            .onAppear { model.updateColumnEstimate(width: gridWidth(geo.size.width)) }
            .onChange(of: geo.size.width) { _, width in
                model.updateColumnEstimate(width: gridWidth(width))
            }
            .onChange(of: model.thumbnailSide) { _, _ in
                model.updateColumnEstimate(width: gridWidth(geo.size.width))
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

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sectionTitle(section))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.inkColor)
            if let place = section.place, !place.isEmpty {
                Image(systemName: "mappin")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryColor)
                Text(place)
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(sectionCount(section.assets))
                .font(StillroomFont.metadata)
                .foregroundStyle(Palette.secondaryColor)
        }
        .padding(.horizontal, Metrics.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.canvasColor)
    }

    private func sectionTitle(_ section: TimelineSection) -> String {
        guard !section.title.isEmpty else { return "" }
        guard let date = section.assets.compactMap(\.createdAt).first else { return section.title }
        switch model.timelineScale {
        case .days: return Format.longDay(date)
        case .months: return Format.monthYear(date)
        case .years: return Format.year(date)
        case .all: return ""
        }
    }

    private func sectionCount(_ assets: [Asset]) -> String {
        let photos = assets.filter { $0.mediaKind == .photo || $0.mediaKind == .screenshot }.count
        let videos = assets.count - photos
        if videos == 0 { return Format.countPhrase(assets.count, singular: "photo", plural: "photos") }
        if photos == 0 { return Format.countPhrase(assets.count, singular: "video", plural: "videos") }
        return Format.countPhrase(assets.count, singular: "item", plural: "items")
    }

    private func gridWidth(_ container: CGFloat) -> CGFloat {
        max(0, container - Metrics.pageInset * 2)
    }

    private func photoGrid(_ assets: [Asset], width: CGFloat, captions: Bool) -> some View {
        let spacing = Metrics.gridSpacing
        let minimum = max(80, CGFloat(model.thumbnailSide))
        let usable = max(minimum, width)
        let count = max(1, Int((usable + spacing) / (minimum + spacing)))
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: count)
        return LazyVGrid(columns: columns, spacing: captions ? 14 : spacing) {
            ForEach(assets) { asset in
                VStack(alignment: .leading, spacing: 6) {
                    PhotoTile(
                        model: model,
                        asset: asset,
                        side: minimum,
                        selected: model.selectedAssets.contains { $0.id == asset.id }
                    )
                    if captions {
                        Text(resultCaption(asset))
                            .font(StillroomFont.caption)
                            .foregroundStyle(Palette.secondaryColor)
                            .lineLimit(1)
                    }
                }
                .id(asset.id)
            }
        }
        .frame(width: usable, alignment: .leading)
    }

    private func resultCaption(_ asset: Asset) -> String {
        var parts: [String] = []
        if let place = TimelineGrouping.displayPlace(for: asset) {
            parts.append(place)
        }
        if let date = asset.createdAt {
            parts.append(Format.shortMonthDay(date))
        }
        return parts.joined(separator: " · ")
    }

    private var searchResults: some View {
        let assets = orderedResults
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.combinedSearchText)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Palette.inkColor)
                    .lineLimit(2)
                Text(Format.countPhrase(assets.count, singular: "result", plural: "results"))
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
                HStack(spacing: 12) {
                    resultScopes
                    Spacer(minLength: 8)
                    Label("On-device search", systemImage: "lock")
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                    Menu {
                        Button("Relevance") { resultOrder = .relevance }
                        Button("Newest") { resultOrder = .newest }
                        Button("Oldest") { resultOrder = .oldest }
                    } label: {
                        Text("Sort: \(resultOrder.title)")
                            .font(StillroomFont.control)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, Metrics.pageInset)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geo in
                ScrollView {
                    photoGrid(assets, width: gridWidth(geo.size.width), captions: true)
                        .padding(.horizontal, Metrics.pageInset)
                        .padding(.bottom, 12)
                }
            }
            Text("Results found privately on the Mac")
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var resultScopes: some View {
        HStack(spacing: 2) {
            scopeButton("All Photos", .all)
            scopeButton("Photos", .photos)
            scopeButton("Videos", .videos)
        }
        .padding(3)
        .background(Palette.inkColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func scopeButton(_ title: String, _ scope: ResultScope) -> some View {
        let on = resultScope == scope
        return Button {
            resultScope = scope
        } label: {
            Text(title)
                .font(StillroomFont.controlMedium)
                .foregroundStyle(on ? Color.white : Palette.inkColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var orderedResults: [Asset] {
        let filtered: [Asset]
        switch resultScope {
        case .all:
            filtered = model.assets
        case .photos:
            filtered = model.assets.filter { $0.mediaKind == .photo || $0.mediaKind == .screenshot }
        case .videos:
            filtered = model.assets.filter { $0.mediaKind == .video || $0.mediaKind == .screenRecording }
        }
        switch resultOrder {
        case .relevance:
            return filtered
        case .newest:
            return filtered.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .oldest:
            return filtered.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
    }

    private var placesPage: some View {
        ZStack(alignment: .bottom) {
            if model.mapPoints.isEmpty {
                ContentUnavailableView(
                    "No places yet",
                    systemImage: "mappin.and.ellipse",
                    description: Text("Geotagged photos show up on the map. Stillroom reads coordinates already in the file.")
                )
            } else {
                PlacesMapView(model: model) { ids in
                    model.selectPlaceCluster(ids)
                } onFocus: { ids in
                    model.focusPlaceCluster(ids)
                }
            }
            if let ids = model.placeMemberIDs, !ids.isEmpty {
                placeStrip(ids)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private func placeStrip(_ ids: [String]) -> some View {
        let assets = ids.compactMap { model.asset(id: $0) }
        let place = TimelineGrouping.dominantPlace(in: assets) ?? "Place"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place)
                        .font(StillroomFont.section)
                        .foregroundStyle(Palette.inkColor)
                    Text(Format.countPhrase(assets.count, singular: "photo", plural: "photos"))
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                }
                Spacer()
                Button {
                    model.selectPlaces()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondaryColor)
                .help("Show every place")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(assets) { asset in
                        PhotoTile(model: model, asset: asset, side: 120, selected: model.selectedAssets.contains { $0.id == asset.id })
                            .frame(width: 148, height: 96)
                    }
                }
            }
        }
        .padding(14)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var peoplePage: some View {
        let people = sortedClusters.filter { $0.kind == .person }
        let pets = sortedClusters.filter { $0.kind != .person }
        return Group {
            if model.subjectClusters.isEmpty {
                ContentUnavailableView(
                    "People & Pets",
                    systemImage: "person.2",
                    description: Text("Faces and pets are grouped on this Mac after photos are read. Nothing is uploaded.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Familiar faces, found on this Mac.")
                            .font(StillroomFont.metadata)
                            .foregroundStyle(Palette.secondaryColor)
                        portraitGrid(people)
                        if !pets.isEmpty {
                            Divider()
                            Text("Pets")
                                .font(StillroomFont.section)
                                .foregroundStyle(Palette.inkColor)
                            portraitGrid(pets)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func portraitGrid(_ clusters: [SubjectClusterRecord]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 18)], spacing: 22) {
            ForEach(clusters) { cluster in
                personCard(cluster)
            }
        }
    }

    private var sortedClusters: [SubjectClusterRecord] {
        model.subjectClusters.sorted { lhs, rhs in
            let leftNamed = !lhs.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let rightNamed = !rhs.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if leftNamed != rightNamed { return leftNamed && !rightNamed }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return model.displayName(for: lhs).localizedCaseInsensitiveCompare(model.displayName(for: rhs)) == .orderedAscending
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
            .frame(width: 112, height: 112)
            .overlay {
                if selected {
                    Circle().strokeBorder(Palette.accentColor, lineWidth: 3)
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
            .font(StillroomFont.controlMedium)
            .foregroundStyle(named ? Palette.inkColor : Palette.accentColor)
            .lineLimit(1)
            Text(Format.countPhrase(cluster.count, singular: "photo", plural: "photos"))
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
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

    private func personHeader(_ cluster: SubjectClusterRecord) -> some View {
        let named = !cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let years = model.assets.compactMap(\.createdAt).map { Calendar.current.component(.year, from: $0) }
        let span: String = {
            guard let first = years.min(), let last = years.max() else {
                return Format.countPhrase(cluster.count, singular: "photo", plural: "photos")
            }
            let count = Format.countPhrase(cluster.count, singular: "photo", plural: "photos")
            if first == last { return "\(count) · \(first)" }
            return "\(count) · \(first)–\(last)"
        }()
        let others = model.subjectClusters.filter { $0.kind == cluster.kind && $0.id != cluster.id }
        return HStack(alignment: .center, spacing: 16) {
            FaceBubble(
                model: model,
                assetID: cluster.coverAssetID,
                box: cluster.coverBox,
                symbol: cluster.kind == .person ? "person.crop.circle" : "pawprint"
            )
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(named ? model.displayName(for: cluster) : "Add Name")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.inkColor)
                    Button {
                        model.renameSubject(cluster)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryColor)
                    .help("Rename")
                }
                Text(span)
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
            }
            Spacer(minLength: 12)
            Button("Rename…") { model.renameSubject(cluster) }
                .buttonStyle(.bordered)
            Menu("Merge…") {
                ForEach(others) { other in
                    Button("Merge into \(model.displayName(for: other))") {
                        model.mergeSubject(cluster, into: other.id)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(others.isEmpty)
        }
        .padding(.horizontal, Metrics.pageInset)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var memoriesPage: some View {
        let featured = featuredStories
        let more = moreStories
        return Group {
            if model.stories.isEmpty {
                ContentUnavailableView(
                    "Memories",
                    systemImage: "rectangle.stack",
                    description: Text("Shuffle a memory once the library has a few days of photos. Playback stays on this Mac.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !featured.isEmpty {
                            Text("For You")
                                .font(StillroomFont.section)
                                .foregroundStyle(Palette.inkColor)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                                ForEach(featured) { story in
                                    memoryCard(story, tall: true)
                                }
                            }
                        }
                        if !more.isEmpty {
                            Text("Worth another look")
                                .font(StillroomFont.section)
                                .foregroundStyle(Palette.inkColor)
                                .padding(.top, 6)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                                ForEach(more) { story in
                                    memoryCard(story, tall: false)
                                }
                            }
                        }
                        Label("Made privately on your Mac", systemImage: "lock")
                            .font(StillroomFont.caption)
                            .foregroundStyle(Palette.secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    }
                    .padding(24)
                }
            }
        }
    }

    private var featuredStories: [HighlightStory] {
        let primary = model.stories.filter { $0.kind == .forYou || $0.kind == .trip }
        if !primary.isEmpty { return primary }
        return Array(supportingStories.prefix(2))
    }

    private var supportingStories: [HighlightStory] {
        model.stories.filter { $0.kind != .forYou && $0.kind != .trip && $0.kind != .roulette }
    }

    private var moreStories: [HighlightStory] {
        let used = Set(featuredStories.map(\.id))
        return supportingStories.filter { !used.contains($0.id) }
    }

    private func memoryCard(_ story: HighlightStory, tall: Bool) -> some View {
        let coverID = story.assetIDs.first
        return ZStack(alignment: .bottomLeading) {
            MemoryCover(model: model, assetID: coverID)
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(story.kind == .forYou ? "For You" : story.title)
                    .font(.system(size: tall ? 20 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(storyDetail(story))
                    .font(StillroomFont.caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
            }
            .padding(14)
            Button {
                model.play(story)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkColor)
                    .frame(width: 32, height: 32)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .help("Play")
        }
        .frame(maxWidth: .infinity)
        .frame(height: tall ? 250 : 168)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.showStory(story) }
    }

    private func storyDetail(_ story: HighlightStory) -> String {
        let dates = story.assetIDs.compactMap { model.asset(id: $0)?.createdAt }
        let count = Format.countPhrase(story.count, singular: "photo", plural: "photos")
        guard let start = dates.min(), let end = dates.max() else { return count }
        let calendar = Calendar.current
        if calendar.isDate(start, equalTo: end, toGranularity: .day) {
            return "\(Format.longDay(start)) · \(count)"
        }
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(Format.monthYear(start)) · \(count)"
        }
        return "\(Format.shortMonthDay(start))–\(Format.shortMonthDay(end)) · \(count)"
    }

    private var duplicatesPage: some View {
        let blocks = model.gridBlocks ?? []
        return Group {
            if blocks.isEmpty {
                ContentUnavailableView(
                    "No duplicates",
                    systemImage: "square.on.square",
                    description: Text("Exact copies share a file hash. Similar photos appear after this Mac reads them. Nothing is deleted.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Compare copies. Your originals stay untouched.", systemImage: "info.circle")
                            .font(StillroomFont.control)
                            .foregroundStyle(Palette.inkColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        ForEach(blocks) { block in
                            duplicateGroup(block)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private func duplicateGroup(_ block: GridBlock) -> some View {
        let exact = block.id.hasPrefix("exact:")
        let place = TimelineGrouping.dominantPlace(in: block.assets)
        let name = place ?? Format.fileName(block.assets[0])
        let noun = exact ? (block.assets.count == 1 ? "identical photo" : "identical photos") : (block.assets.count == 1 ? "similar photo" : "similar photos")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(name)  |  \(block.assets.count) \(noun)")
                    .font(StillroomFont.section)
                    .foregroundStyle(Palette.inkColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(exact ? "Exact matches" : "Similar")
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(block.assets) { asset in
                    duplicateCard(asset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
    }

    private func duplicateCard(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssetThumb(model: model, asset: asset, pointSize: 480)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(Format.fileName(asset))
                .font(StillroomFont.controlMedium)
                .foregroundStyle(Palette.inkColor)
                .lineLimit(1)
            Text(duplicateMeta(asset))
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
                .lineLimit(1)
            if let folder = Format.folderName(asset) {
                Text(folder)
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .lineLimit(1)
            }
            if asset.filePath != nil {
                Button("Show in Finder") { model.reveal(asset) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func duplicateMeta(_ asset: Asset) -> String {
        var parts: [String] = []
        if let size = asset.fileSize { parts.append(Format.bytes(size)) }
        if let dimensions = Format.dimensions(width: asset.pixelWidth, height: asset.pixelHeight) {
            parts.append(dimensions)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.browse == .library, model.selectedKind == nil, model.selectedSourceID == nil, model.counts.enabledTotal == 0 {
            firstRun
        } else {
            ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyDetail))
        }
    }

    private var firstRun: some View {
        VStack(spacing: 16) {
            AppMark(size: 76)
            Text("Your photos. Right where they belong.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.inkColor)
                .multilineTextAlignment(.center)
            Text("Bring your folders together in one private library.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.secondaryColor)
            HStack(spacing: 10) {
                Button("Add Folder…") { model.addFolder() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentColor)
                    .controlSize(.large)
                Button("Import from iPhone…") { model.openImport() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .padding(.top, 4)
            Text("Stillroom indexes your photos. It never moves or changes the originals.")
                .font(StillroomFont.metadata)
                .foregroundStyle(Palette.secondaryColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            VStack(spacing: 0) {
                firstRunRow(
                    symbol: "photo.on.rectangle.angled",
                    title: "Photos Library",
                    detail: "Connect your existing library",
                    button: "Allow Access…"
                ) {
                    if let source = model.sources.first(where: { $0.id == Source.photosLibraryID }), !source.enabled {
                        model.setEnabled(true, sourceID: source.id)
                    }
                    model.rescan()
                }
                Divider()
                firstRunRow(
                    symbol: "rectangle.dashed",
                    title: "Screenshots",
                    detail: "CleanShot, Shottr and macOS",
                    button: "Choose Folders…"
                ) {
                    model.addFolder()
                }
            }
            .frame(maxWidth: 560)
            .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.borderColor)
            }
            Label("Everything stays on this Mac. No account needed.", systemImage: "lock")
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func firstRunRow(symbol: String, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Palette.accentColor)
                .frame(width: 36, height: 36)
                .background(Palette.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StillroomFont.controlMedium)
                    .foregroundStyle(Palette.inkColor)
                Text(detail)
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
            }
            Spacer(minLength: 8)
            Button(button, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var hiddenLock: some View {
        ZStack {
            Palette.canvasColor.opacity(0.96)
            VStack(spacing: 36) {
                if model.hiddenPromptVisible {
                    VStack(spacing: 12) {
                        Image(systemName: "touchid")
                            .font(.system(size: 36))
                            .foregroundStyle(Color(red: 0.93, green: 0.33, blue: 0.42))
                        Text("Unlock Hidden")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.inkColor)
                        Text("Stillroom wants to use Touch ID to unlock the Hidden album.")
                            .font(StillroomFont.metadata)
                            .foregroundStyle(Palette.secondaryColor)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                        Text("Place your finger on Touch ID.")
                            .font(StillroomFont.metadata)
                            .foregroundStyle(Palette.secondaryColor)
                        HStack(spacing: 10) {
                            Button("Cancel") { model.dismissHiddenPrompt() }
                                .buttonStyle(.bordered)
                            Button("Use Password…") { model.unlockHidden() }
                                .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .padding(22)
                    .frame(width: 360)
                    .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.borderColor)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
                }
                VStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.secondaryColor)
                    Text("Hidden is locked")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Palette.inkColor)
                    Text("Use Touch ID to view your hidden photos.")
                        .font(StillroomFont.metadata)
                        .foregroundStyle(Palette.secondaryColor)
                    Button("Unlock") { model.unlockHidden() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accentColor)
                        .padding(.top, 6)
                        .disabled(model.authenticatingHidden)
                }
            }
            VStack {
                Spacer()
                Text("Hidden in Stillroom. Original files remain accessible in Finder.")
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .padding(.bottom, 14)
            }
        }
    }

    private var emptySymbol: String {
        switch model.browse {
        case .places: return "mappin.and.ellipse"
        case .people: return "person.2"
        case .highlights: return "rectangle.stack"
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

private enum ResultScope {
    case all
    case photos
    case videos
}

private enum ResultOrder {
    case relevance
    case newest
    case oldest

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }
}

private struct PhotoTile: View {
    var model: AppModel
    var asset: Asset
    var side: Double
    var selected: Bool
    @State private var image: NSImage?
    @State private var revealed = false
    @State private var hovering = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        Rectangle().fill(Palette.borderColor.opacity(0.45))
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(revealed ? 1 : 0)
                        } else {
                            Image(systemName: Format.mediaSymbol(asset.mediaKind))
                                .font(.title3)
                                .foregroundStyle(Palette.secondaryColor)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Palette.accentColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if hovering || asset.isFavorite {
                    Button {
                        model.setFavorite(!asset.isFavorite, assets: [asset])
                    } label: {
                        Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
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
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { model.openViewer(asset) }
            .onTapGesture(count: 1) { model.click(asset) }
            .onDrag {
                guard let path = asset.filePath else { return NSItemProvider() }
                return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
            }
            .contextMenu { tileMenu }
            .task(id: "\(asset.id)|\(asset.contentHash ?? "")|\(Int(side))") {
                revealed = false
                let loaded = await model.thumbnails?.image(for: asset, pointSize: CGFloat(side), scale: 2, quality: .grid)
                guard !Task.isCancelled else { return }
                image = loaded
                withAnimation(.easeIn(duration: 0.15)) {
                    revealed = true
                }
            }
            .accessibilityLabel(Format.fileName(asset))
            .accessibilityAddTraits(selected ? .isSelected : [])
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

struct AssetThumb: View {
    var model: AppModel
    var asset: Asset
    var pointSize: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.borderColor.opacity(0.35)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task(id: asset.id) {
            image = await model.thumbnails?.image(for: asset, pointSize: pointSize, scale: 2, quality: .grid)
        }
    }
}

private struct MemoryCover: View {
    var model: AppModel
    var assetID: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.markGradient
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: assetID) {
            image = nil
            guard let assetID, let asset = model.asset(id: assetID) else { return }
            image = await model.thumbnails?.image(for: asset, pointSize: 640, scale: 2, quality: .preview)
        }
    }
}

struct PhotoViewer: View {
    var model: AppModel
    var asset: Asset
    @State private var image: NSImage?
    @FocusState private var focused: Bool

    var body: some View {
        let strip = neighbors
        let index = strip.firstIndex { $0.id == asset.id } ?? 0
        VStack(spacing: 0) {
            ZStack {
                Palette.canvasColor
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 72)
                        .padding(.vertical, 24)
                        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                HStack {
                    chevron("chevron.left") { model.moveSelection(delta: -1) }
                    Spacer()
                    chevron("chevron.right") { model.moveSelection(delta: 1) }
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(strip) { item in
                        AssetThumb(model: model, asset: item, pointSize: 120)
                            .frame(width: 72, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay {
                                if item.id == asset.id {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Palette.accentColor, lineWidth: 2)
                                }
                            }
                            .onTapGesture {
                                model.openViewer(item)
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Text("\(index + 1) of \(max(strip.count, 1))")
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
                .padding(.vertical, 8)
        }
        .background(Palette.canvasColor)
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

    private var neighbors: [Asset] {
        let sections = model.visibleSections()
        if let section = sections.first(where: { $0.assets.contains { $0.id == model.viewerAssetID } }) {
            return section.assets
        }
        let flat = model.flatAssets()
        return flat.isEmpty ? [asset] : flat
    }

    private func chevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkColor)
                .frame(width: 32, height: 32)
                .background(Palette.raisedColor, in: Circle())
                .overlay(Circle().strokeBorder(Palette.borderColor))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
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
