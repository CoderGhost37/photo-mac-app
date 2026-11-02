import AppKit
import PhotoIndex
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @AppStorage("sidebar.mediaTypesExpanded") private var mediaTypesExpanded = false
    @AppStorage("sidebar.memoriesExpanded") private var memoriesExpanded = true
    @AppStorage("sidebar.utilitiesExpanded") private var utilitiesExpanded = true
    @AppStorage("sidebar.sourcesExpanded") private var sourcesExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Library") {
                    Label("All Photos", systemImage: "photo.on.rectangle")
                        .badge(model.counts.enabledTotal)
                        .tag(SidebarSelection.all)
                    Label {
                        Text("Favorites")
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Palette.favoriteColor)
                    }
                    .badge(model.counts.favoriteCount)
                    .tag(SidebarSelection.favorites)
                    Label("Recents", systemImage: "clock")
                        .badge(model.recentCount)
                        .tag(SidebarSelection.recents)
                }

                Section("Media Types", isExpanded: $mediaTypesExpanded) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        Label(Format.mediaTitle(kind), systemImage: Format.mediaSymbol(kind))
                            .badge(model.counts.byMediaKind[kind] ?? 0)
                            .tag(SidebarSelection.kind(kind))
                    }
                }

                Section("Places") {
                    Label("Map", systemImage: "map")
                        .badge(model.mapPoints.count)
                        .tag(SidebarSelection.map)
                }

                Section("People & Pets") {
                    Label("People & Pets", systemImage: "person.2")
                        .badge(model.subjectClusters.count)
                        .tag(SidebarSelection.people)
                }

                Section("Memories", isExpanded: $memoriesExpanded) {
                    if model.sidebarStories.isEmpty {
                        Text("Memories appear when the library has places, people, or trips.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.sidebarStories) { story in
                        Label {
                            Text(story.kind == .forYou ? "For You" : story.title)
                        } icon: {
                            Image(systemName: symbol(for: story.kind))
                                .foregroundStyle(Palette.favoriteColor)
                        }
                        .badge(story.count)
                        .tag(SidebarSelection.story(story.id))
                    }
                }

                Section("Utilities", isExpanded: $utilitiesExpanded) {
                    Label("Duplicates", systemImage: "square.on.square")
                        .badge(model.duplicateGroups.count)
                        .tag(SidebarSelection.duplicates)
                    Button {
                        model.openConvert()
                    } label: {
                        Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Convert selected files, or drop files in the panel")
                    Button {
                        model.openPDF()
                    } label: {
                        Label("Make PDF", systemImage: "doc.richtext")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Make a PDF from the selection, or drop files in the panel")
                    Label {
                        Text("Hidden")
                    } icon: {
                        Image(systemName: model.hiddenUnlocked ? "lock.open" : "lock")
                    }
                    .badge(model.counts.hiddenCount)
                    .tag(SidebarSelection.hidden)
                }

                Section("Sources", isExpanded: $sourcesExpanded) {
                    ForEach(model.sources) { source in
                        HStack(spacing: 8) {
                            Label(source.displayName, systemImage: Format.sourceSymbol(source.kind))
                                .foregroundStyle(source.enabled ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { source.enabled },
                                    set: { model.setEnabled($0, sourceID: source.id) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help(source.enabled ? "Included in the library" : "Turn on to index this source")
                        }
                        .badge(model.counts.bySource[source.id] ?? 0)
                        .tag(SidebarSelection.source(source.id))
                        .contextMenu {
                            if source.kind == .folder {
                                Button("Remove from Stillroom") {
                                    model.removeFolder(source)
                                }
                            }
                        }
                    }
                    Button {
                        model.addFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.openImport()
                    } label: {
                        Label("Import from iPhone…", systemImage: "iphone")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Copy photos from a connected iPhone. Originals on the device stay put.")
                }
            }
            .listStyle(.sidebar)
            .font(.body)

            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var selection: Binding<SidebarSelection?> {
        Binding {
            model.sidebarSelection
        } set: { newValue in
            guard let newValue else { return }
            model.applySidebar(newValue)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.footer {
        case .current:
            Label("Library is up to date", systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .indexing(let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let progress, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    Label {
                        Text("Indexing \(Format.count(progress.completed)) of \(Format.count(progress.total))")
                    } icon: {
                        ScanningIcon()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .message(let text):
            Label(text, systemImage: model.machinePause == nil ? "exclamationmark.triangle" : "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(for kind: HighlightKind) -> String {
        switch kind {
        case .forYou: return "sparkles"
        case .onThisDay, .yearsAgo: return "calendar"
        case .recentDay: return "clock"
        case .trip: return "airplane"
        case .person: return "person.2"
        case .pet: return "pawprint"
        case .food: return "fork.knife"
        case .roulette: return "sparkles"
        }
    }
}

private struct ScanningIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 240))
        }
    }
}

struct FaceBubble: View {
    var model: AppModel
    var assetID: String?
    var box: NormalizedBox?
    var symbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.06))
        .clipShape(Circle())
        .task(id: assetID) {
            image = nil
            guard let assetID, let asset = model.asset(id: assetID), let thumbnails = model.thumbnails else { return }
            let full = await thumbnails.image(for: asset, pointSize: 180, scale: 2, quality: .grid)
            if !Task.isCancelled {
                image = full.flatMap { cropFace($0, box: box) } ?? full
            }
        }
    }
}

func cropFace(_ image: NSImage, box: NormalizedBox?) -> NSImage? {
    guard let box else { return image }
    var proposed = NSRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return image }
    let width = CGFloat(cg.width)
    let height = CGFloat(cg.height)
    guard width > 1, height > 1 else { return image }
    let rect = CGRect(
        x: box.x * width,
        y: (1 - box.y - box.height) * height,
        width: box.width * width,
        height: box.height * height
    ).integral
    guard rect.width > 2, rect.height > 2, let part = cg.cropping(to: rect) else { return image }
    return NSImage(cgImage: part, size: NSSize(width: rect.width, height: rect.height))
}
