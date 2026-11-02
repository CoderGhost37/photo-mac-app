import AppKit
import PhotoIndex
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Namespace private var photos

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 320)
        } detail: {
            GridView(model: model, namespace: photos)
                .navigationTitle(model.filterTitle)
                .modifier(LibrarySubtitle(text: model.librarySubtitle))
                .toolbar { toolbarContent }
                .searchable(
                    text: $model.searchText,
                    tokens: $model.searchTokens,
                    placement: .toolbar,
                    prompt: Text("Search")
                ) { token in
                    Label(token.value, systemImage: token.symbol)
                }
                .searchSuggestions {
                    ForEach(model.searchSuggestions) { suggestion in
                        Button {
                            model.addSearchToken(suggestion)
                        } label: {
                            Label(suggestion.suggestionTitle, systemImage: suggestion.symbol)
                        }
                    }
                }
        }
        .inspector(isPresented: $model.inspectorVisible) {
            InspectorView(model: model)
        }
        .inspectorColumnWidth(min: 220, ideal: 280, max: 340)
        .tint(.accentColor)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Palette.navyTint
            }
            .ignoresSafeArea()
        }
        .overlay {
            if let story = model.playingStory {
                HighlightPlayback(model: model, story: story)
            } else if let id = model.viewerAssetID, let asset = model.asset(id: id) {
                PhotoViewer(model: model, asset: asset, namespace: photos)
            }
        }
        .background {
            QuickLookHost(bridge: model.quickLook)
                .frame(width: 0, height: 0)
        }
        .preferredColorScheme(ScreenshotSession.isEnabled ? .dark : nil)
        .onChange(of: model.searchText) { _, _ in
            model.searchChanged()
        }
        .onChange(of: model.searchTokens) { _, _ in
            model.searchChanged()
        }
        .onChange(of: model.findToken) { _, _ in
            focusSearchField()
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.showsTimelinePicker {
            ToolbarItem(placement: .principal) {
                Picker("Grouping", selection: $model.timelineScale) {
                    Text("Years").tag(TimelineScale.years)
                    Text("Months").tag(TimelineScale.months)
                    Text("Days").tag(TimelineScale.days)
                    Text("All Photos").tag(TimelineScale.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .help("Group photos by year, month, day, or show all of them")
            }
        }
        if model.browse == .people, model.selectedSubjectID != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.selectPeople()
                } label: {
                    Label("People & Pets", systemImage: "chevron.backward")
                }
                .help("Back to People & Pets")
            }
        }
        if model.browse == .highlights {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.shuffleMemory()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .help("Shuffle a memory")
            }
            if let story = model.shownStory {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.play(story)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .help("Play this memory")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $model.thumbnailSide, in: 80...320)
                    .frame(width: 90)
                    .tint(.accentColor)
                    .help("Thumbnail size")
                Image(systemName: "photo.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .help("Thumbnail size")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let root = window.contentView else { return }
            if let field = findSearchField(in: root) {
                window.makeFirstResponder(field)
            }
        }
    }

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = findSearchField(in: subview) { return field }
        }
        return nil
    }
}

private struct LibrarySubtitle: ViewModifier {
    var text: String

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.navigationSubtitle(text)
        } else {
            content.toolbar {
                ToolbarItem(placement: .automatic) {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
