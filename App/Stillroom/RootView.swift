import AppKit
import PhotoIndex
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Namespace private var photos
    @FocusState private var searchFocused: Bool
    @FocusState private var placeFocused: Bool
    @State private var suggestionsPinned = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 280)
        } detail: {
            detail
                .navigationTitle("")
                .toolbar { toolbarContent }
                .overlay(alignment: .topTrailing) {
                    if showSuggestions {
                        SearchSuggestionPanel(model: model) {
                            suggestionsPinned = false
                            searchFocused = false
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 16)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $model.inspectorVisible) {
            InspectorView(model: model)
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        .tint(Palette.accentColor)
        .toolbarBackground(Palette.canvasColor, for: .windowToolbar)
        .background(Palette.canvasColor.ignoresSafeArea())
        .preferredColorScheme(model.forcedColorScheme)
        .overlay {
            if let story = model.playingStory {
                HighlightPlayback(model: model, story: story)
            }
        }
        .background {
            QuickLookHost(bridge: model.quickLook)
                .frame(width: 0, height: 0)
        }
        .onChange(of: model.searchText) { _, text in
            model.searchChanged()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, searchFocused {
                suggestionsPinned = true
            }
        }
        .onChange(of: model.searchTokens) { _, _ in
            model.searchChanged()
        }
        .onChange(of: model.findToken) { _, _ in
            if model.browse == .places, model.viewerAssetID == nil, !model.isSearching {
                placeFocused = true
            } else {
                searchFocused = true
                if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    suggestionsPinned = true
                }
            }
        }
        .onChange(of: searchFocused) { _, focused in
            if focused, !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                suggestionsPinned = true
            }
            if !focused {
                Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if !searchFocused {
                        suggestionsPinned = false
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.noteInactive()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"))) { _ in
            model.refreshLimits()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            model.refreshLimits()
        }
        .sheet(item: $model.presentedTool) { tool in
            switch tool {
            case .convert:
                ConvertPanel(model: model, session: model.convertSession)
            case .pdf:
                PDFPanel(model: model, session: model.pdfSession)
            case .deviceImport:
                DeviceImportPanel(model: model, session: model.importSession)
            }
        }
        .task {
            if !ScreenshotSession.isEnabled {
                model.start()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.viewerAssetID, let asset = model.asset(id: id) {
            PhotoViewer(model: model, asset: asset)
        } else {
            GridView(model: model, namespace: photos)
        }
    }

    private var showSuggestions: Bool {
        guard suggestionsPinned, model.viewerAssetID == nil else { return false }
        return !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            titleStack
        }
        if let asset = viewedAsset {
            ToolbarItem(placement: .principal) {
                Text(Format.viewerStamp(asset.createdAt))
                    .font(StillroomFont.control)
                    .foregroundStyle(Palette.secondaryColor)
            }
        } else if model.showsTimelinePicker {
            ToolbarItem(placement: .principal) {
                TimelinePicker(scale: $model.timelineScale)
            }
        }
        if model.browse == .people, model.selectedSubjectID != nil, model.viewerAssetID == nil {
            ToolbarItem(placement: .navigation) {
                backButton("People & Pets") { model.selectPeople() }
            }
        }
        if model.browse == .highlights, model.shownStory != nil, model.viewerAssetID == nil, !model.isSearching {
            ToolbarItem(placement: .navigation) {
                backButton("Memories") { model.selectMemories() }
            }
        }
        if model.browse == .highlights, let story = model.shownStory, model.viewerAssetID == nil, !model.isSearching {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.play(story)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .help("Play this memory")
            }
        }
        if model.browse == .highlights, model.shownStory == nil, model.viewerAssetID == nil, !model.isSearching {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.shuffleMemory()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentColor)
                .help("Shuffle a memory")
            }
        }
        if model.browse == .people, model.selectedSubjectID == nil, model.viewerAssetID == nil, !model.isSearching {
            ToolbarItem(placement: .primaryAction) {
                peopleToolbar
            }
        }
        if model.viewerAssetID != nil, let asset = viewedAsset {
            ToolbarItem(placement: .primaryAction) {
                viewerTools(asset)
            }
        }
        if model.browse == .places, model.viewerAssetID == nil, !model.isSearching {
            ToolbarItem(placement: .primaryAction) {
                placesTools
            }
        }
        if model.showsZoom {
            ToolbarItem(placement: .primaryAction) {
                zoomSlider
            }
        }
        if showsInspectorButton {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.inspectorVisible.toggle()
                } label: {
                    Image(systemName: model.viewerAssetID == nil ? "sidebar.trailing" : "info.circle.fill")
                }
                .help(model.inspectorVisible ? "Hide Info" : "Show Info")
                .foregroundStyle(model.inspectorVisible && model.viewerAssetID != nil ? Palette.accentColor : Palette.inkColor)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.browse == .places, model.viewerAssetID == nil, !model.isSearching {
                placeSearch
            } else {
                librarySearch
            }
        }
    }

    private var viewedAsset: Asset? {
        guard let id = model.viewerAssetID else { return nil }
        return model.asset(id: id)
    }

    private var showsInspectorButton: Bool {
        if model.hiddenLockPresented { return false }
        if model.isSearching { return false }
        switch model.browse {
        case .places, .highlights:
            return model.viewerAssetID != nil
        case .people:
            return model.selectedSubjectID != nil || model.viewerAssetID != nil
        default:
            return true
        }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.filterTitle)
                .font(model.usesLargeTitle ? StillroomFont.title : StillroomFont.section)
                .foregroundStyle(Palette.inkColor)
                .lineLimit(1)
            if model.usesLargeTitle, !model.librarySubtitle.isEmpty {
                Text(model.librarySubtitle)
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, model.usesLargeTitle ? 2 : 0)
    }

    private func backButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(StillroomFont.control)
                .foregroundStyle(Palette.inkColor)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var zoomSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 11))
            Slider(value: $model.thumbnailSide, in: 80...320)
                .frame(width: 92)
                .controlSize(.small)
                .tint(Palette.accentColor)
            Image(systemName: "photo.fill")
                .font(.system(size: 13))
        }
        .foregroundStyle(Palette.secondaryColor)
        .help("Thumbnail size")
    }

    private var librarySearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryColor)
            if !model.searchTokens.isEmpty {
                ForEach(model.searchTokens) { token in
                    HStack(spacing: 4) {
                        Text(token.value)
                            .lineLimit(1)
                        Button {
                            model.searchTokens.removeAll { $0.id == token.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(StillroomFont.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Palette.inkColor)
                }
            }
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(StillroomFont.control)
                .focused($searchFocused)
                .frame(minWidth: 88)
                .onSubmit {
                    suggestionsPinned = false
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: model.searchTokens.isEmpty ? 196 : 280)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? Palette.accentColor : Palette.borderColor, lineWidth: searchFocused ? 1.5 : 1)
        }
    }

    private var placeSearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryColor)
            TextField("Search places", text: $model.placeQuery)
                .textFieldStyle(.plain)
                .font(StillroomFont.control)
                .focused($placeFocused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 180)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(placeFocused ? Palette.accentColor : Palette.borderColor, lineWidth: 1)
        }
    }

    private var placesTools: some View {
        HStack(spacing: 8) {
            Button {
                model.mapFitToken += 1
            } label: {
                Image(systemName: "location")
            }
            .buttonStyle(.borderless)
            .help("Show every place")
            TimelinePicker(
                labels: [("Map", false), ("Satellite", true)],
                selected: model.mapUsesSatellite,
                choose: { model.mapUsesSatellite = $0 }
            )
        }
    }

    @ViewBuilder
    private var peopleToolbar: some View {
        let cluster = model.subjectClusters.first { $0.id == model.highlightedSubjectID }
        HStack(spacing: 8) {
            Menu {
                Button("Rename…") {
                    if let cluster { model.renameSubject(cluster) }
                }
                .disabled(cluster == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 22)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .frame(width: 36)
            .help("More")
            mergeMenu(for: cluster, title: "Merge…")
        }
    }

    private func viewerTools(_ asset: Asset) -> some View {
        HStack(spacing: 8) {
            Button {
                let targets = model.selectedAssets.contains(where: { $0.id == asset.id }) ? model.selectedAssets : [asset]
                model.setFavorite(!asset.isFavorite, assets: targets)
            } label: {
                Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(asset.isFavorite ? Palette.accentColor : Palette.inkColor)
            .help(asset.isFavorite ? "Remove from Favorites" : "Favorite")
            Button {
                model.share(asset)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(asset.filePath == nil)
            .help("Share")
            Text("Fit")
                .font(StillroomFont.controlMedium)
                .foregroundStyle(Palette.inkColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Palette.borderColor)
                )
                .help("Scaled to fit")
        }
    }

    @ViewBuilder
    private func mergeMenu(for cluster: SubjectClusterRecord?, title: String) -> some View {
        let others = model.subjectClusters.filter { candidate in
            guard let cluster else { return false }
            return candidate.kind == cluster.kind && candidate.id != cluster.id
        }
        Menu(title) {
            if let cluster {
                ForEach(others) { other in
                    Button("Merge into \(model.displayName(for: other))") {
                        model.mergeSubject(cluster, into: other.id)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(cluster == nil || others.isEmpty)
    }
}

struct TimelinePicker: View {
    var scale: Binding<TimelineScale>? = nil
    var labels: [(String, Bool)]? = nil
    var selected: Bool? = nil
    var choose: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            if let scale {
                segment("Years", on: scale.wrappedValue == .years) { scale.wrappedValue = .years }
                segment("Months", on: scale.wrappedValue == .months) { scale.wrappedValue = .months }
                segment("Days", on: scale.wrappedValue == .days) { scale.wrappedValue = .days }
                segment("All", on: scale.wrappedValue == .all) { scale.wrappedValue = .all }
            } else if let labels, let selected, let choose {
                ForEach(labels, id: \.0) { label in
                    segment(label.0, on: selected == label.1) { choose(label.1) }
                }
            }
        }
        .padding(3)
        .background(Palette.inkColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
}

private struct SearchSuggestionPanel: View {
    var model: AppModel
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search your library")
                .font(StillroomFont.section)
                .foregroundStyle(Palette.inkColor)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            suggestionRow(
                title: "Search for “\(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines))”",
                subtitle: nil,
                systemImage: "magnifyingglass",
                highlighted: true
            ) {
                dismiss()
            }
            grouped("People", tokens: model.searchSuggestions.filter { $0.kind == .person })
            grouped("Places", tokens: model.searchSuggestions.filter { $0.kind == .place })
            grouped("Dates", tokens: model.searchSuggestions.filter { $0.kind == .date })
            grouped("Text", tokens: model.searchSuggestions.filter { $0.kind == .text })
            Divider().padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Label("Search stays on this Mac", systemImage: "lock")
                Text("Try a description, like dogs at the beach")
            }
            .font(StillroomFont.caption)
            .foregroundStyle(Palette.secondaryColor)
            .padding(12)
        }
        .frame(width: 340)
        .background(Palette.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }

    @ViewBuilder
    private func grouped(_ title: String, tokens: [LibrarySearchToken]) -> some View {
        if !tokens.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondaryColor)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(tokens) { token in
                suggestionRow(
                    title: rowTitle(token),
                    subtitle: rowSubtitle(token),
                    systemImage: token.symbol,
                    person: token.kind == .person ? person(named: token.value) : nil,
                    highlighted: false
                ) {
                    model.addSearchToken(token)
                    dismiss()
                }
            }
        }
    }

    private func person(named name: String) -> SubjectClusterRecord? {
        model.subjectClusters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func rowTitle(_ token: LibrarySearchToken) -> String {
        switch token.kind {
        case .text:
            return "“\(token.value)” in photos"
        case .date:
            return dateTitle(token.value)
        case .person, .place:
            return token.value
        }
    }

    private func rowSubtitle(_ token: LibrarySearchToken) -> String? {
        switch token.kind {
        case .person, .place:
            guard let count = token.count else { return nil }
            return Format.countPhrase(count, singular: "photo", plural: "photos")
        case .date:
            guard let count = token.count else { return nil }
            return Format.countPhrase(count, singular: "photo", plural: "photos")
        case .text:
            return nil
        }
    }

    private func dateTitle(_ raw: String) -> String {
        let plan = SearchPlan.parse(raw)
        guard let range = plan.dateRange else { return raw }
        let days = range.end.timeIntervalSince(range.start) / 86_400
        if days > 300 { return Format.year(range.start) }
        if days > 2 { return Format.monthYear(range.start) }
        return Format.longDay(range.start)
    }

    private func suggestionRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        person: SubjectClusterRecord? = nil,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let person {
                    FaceBubble(
                        model: model,
                        assetID: person.coverAssetID,
                        box: person.coverBox,
                        symbol: "person.crop.circle"
                    )
                    .frame(width: 28, height: 28)
                } else if highlighted {
                    Image(systemName: systemImage)
                        .frame(width: 28)
                } else if systemImage == "text.quote" {
                    Text("T")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .frame(width: 28, height: 28)
                        .background(Palette.inkColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: systemImage)
                        .frame(width: 28, height: 28)
                        .background(Palette.inkColor.opacity(0.06), in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(StillroomFont.controlMedium)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(StillroomFont.caption)
                            .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Palette.secondaryColor)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Palette.secondaryColor)
            }
            .foregroundStyle(highlighted ? Color.white : Palette.inkColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.accentColor)
                }
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
