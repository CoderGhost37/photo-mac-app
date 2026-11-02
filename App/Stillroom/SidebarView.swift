import AppKit
import PhotoIndex
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stillroom")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.inkColor)
                Text("On this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List {
                Section("Library") {
                    row(
                        title: "All Items",
                        symbol: "square.grid.2x2",
                        count: model.counts.enabledTotal,
                            active: model.browse == .library && model.selectedSourceID == nil && model.selectedKind == nil,
                        showsToggle: false,
                        enabled: true
                    ) {
                        model.selectAll()
                    }
                }

                Section("Media Types") {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        row(
                            title: Format.mediaTitle(kind),
                            symbol: Format.mediaSymbol(kind),
                            count: model.counts.byMediaKind[kind] ?? 0,
                            active: model.browse == .library && model.selectedKind == kind,
                            showsToggle: false,
                            enabled: true
                        ) {
                            model.select(kind: kind)
                        }
                    }
                    row(
                        title: "Duplicates",
                        symbol: "square.on.square",
                        count: model.duplicateGroups.count,
                        active: model.browse == .duplicates,
                        showsToggle: false,
                        enabled: true
                    ) {
                        model.selectDuplicates()
                    }
                }

                Section("Places") {
                    row(
                        title: "Map",
                        symbol: "map",
                        count: model.mapPoints.count,
                        active: model.browse == .places,
                        showsToggle: false,
                        enabled: true
                    ) {
                        model.selectPlaces()
                    }
                }

                Section("People & Pets") {
                    if model.subjectClusters.isEmpty {
                        Text("Faces and pets show up here after photos are read on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(sortedClusters) { cluster in
                            subjectRow(cluster)
                        }
                    }
                }

                Section("Highlights") {
                    Button {
                        model.shuffleMemory()
                    } label: {
                        Label("Shuffle a memory", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accentColor)
                    .padding(.vertical, 4)
                    if model.stories.isEmpty {
                        Text("Stories appear when the library has dates, places, people, or food.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(model.stories) { story in
                            row(
                                title: story.title,
                                symbol: symbol(for: story.kind),
                                count: story.count,
                                active: model.browse == .highlights && model.selectedStoryID == story.id,
                                showsToggle: false,
                                enabled: true
                            ) {
                                model.play(story)
                            }
                        }
                    }
                }

                Section("Hidden") {
                    row(
                        title: "Hidden",
                        symbol: model.hiddenUnlocked ? "lock.open" : "lock",
                        count: model.counts.hiddenCount,
                        active: model.browse == .hidden,
                        showsToggle: false,
                        enabled: true
                    ) {
                        model.selectHidden()
                    }
                }

                Section("Sources") {
                    ForEach(model.sources) { source in
                        row(
                            title: source.displayName,
                            symbol: Format.sourceSymbol(source.kind),
                            count: model.counts.bySource[source.id] ?? 0,
                            active: model.browse == .library && model.selectedSourceID == source.id,
                            showsToggle: true,
                            enabled: source.enabled,
                            toggle: Binding(
                                get: { source.enabled },
                                set: { model.setEnabled($0, sourceID: source.id) }
                            )
                        ) {
                            model.select(sourceID: source.id)
                        }
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
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accentColor)
                    .padding(.vertical, 4)
                    Button {
                        model.openImport()
                    } label: {
                        Label("Import from iPhone…", systemImage: "iphone")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accentColor)
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Palette.sidebarColor)
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

    private func subjectRow(_ cluster: SubjectClusterRecord) -> some View {
        HStack(spacing: 6) {
            FaceBubble(model: model, assetID: cluster.coverAssetID, box: cluster.coverBox, symbol: cluster.kind == .person ? "person.crop.circle" : "pawprint")
            row(
                title: model.displayName(for: cluster),
                symbol: "",
                count: cluster.count,
                active: model.browse == .people && model.selectedSubjectID == cluster.id,
                showsToggle: false,
                enabled: true
            ) {
                model.selectSubject(cluster.id)
            }
        }
        .contextMenu {
            Button("Rename…") {
                model.renameSubject(cluster)
            }
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

    private func kindOrder(_ kind: SubjectKind) -> Int {
        switch kind {
        case .person: return 0
        case .cat: return 1
        case .dog: return 2
        }
    }

    private func symbol(for kind: HighlightKind) -> String {
        switch kind {
        case .forYou: return "heart"
        case .onThisDay, .yearsAgo: return "calendar"
        case .recentDay: return "clock"
        case .trip: return "airplane"
        case .person: return "person.2"
        case .pet: return "pawprint"
        case .food: return "fork.knife"
        case .roulette: return "sparkles"
        }
    }

    private func row(
        title: String,
        symbol: String,
        count: Int,
        active: Bool,
        showsToggle: Bool,
        enabled: Bool,
        toggle: Binding<Bool>? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if !symbol.isEmpty {
                        Image(systemName: symbol)
                            .frame(width: 16)
                            .foregroundStyle(active ? Palette.accentColor : .secondary)
                    }
                    Text(title)
                        .foregroundStyle(enabled ? Palette.inkColor : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.count(count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsToggle, let toggle {
                Toggle("", isOn: toggle)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(enabled ? "Included in the library" : "Turn on to index this source")
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            active ? Palette.accentColor.opacity(0.16) : Color.clear
        )
    }
}

private struct FaceBubble: View {
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
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .background(Palette.accentColor.opacity(0.12))
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

private func cropFace(_ image: NSImage, box: NormalizedBox?) -> NSImage? {
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
