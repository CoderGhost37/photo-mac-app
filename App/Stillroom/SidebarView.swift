import AppKit
import PhotoIndex
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Library") {
                    row("All Photos", systemImage: "photo.on.rectangle", tag: .all)
                    row("Favorites", systemImage: "heart", tag: .favorites)
                    row("Recents", systemImage: "clock", tag: .recents)
                }

                Section("Media Types") {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        row(Format.mediaTitle(kind), systemImage: Format.mediaSymbol(kind), tag: .kind(kind))
                    }
                }

                Section("Explore") {
                    row("Places", systemImage: "mappin.and.ellipse", tag: .map)
                    row("People & Pets", systemImage: "person.2", tag: .people)
                    row("Memories", systemImage: "rectangle.stack", tag: .memories)
                }

                Section("Utilities") {
                    row("Duplicates", systemImage: "square.on.square", tag: .duplicates)
                    Button {
                        model.openConvert()
                    } label: {
                        Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    .help("Convert selected files, or drop files in the panel")
                    Button {
                        model.openPDF()
                    } label: {
                        Label("Make PDF", systemImage: "doc.richtext")
                    }
                    .buttonStyle(.plain)
                    .help("Make a PDF from the selection, or drop files in the panel")
                    row("Hidden", systemImage: model.hiddenUnlocked ? "lock.open" : "lock", tag: .hidden)
                }

                Section("Sources") {
                    ForEach(model.sources) { source in
                        row(
                            source.displayName,
                            systemImage: Format.sourceSymbol(source.kind),
                            tag: .source(source.id),
                            tint: source.enabled ? Palette.inkColor : Palette.secondaryColor
                        )
                            .contextMenu {
                                Button(source.enabled ? "Turn Off" : "Turn On") {
                                    model.setEnabled(!source.enabled, sourceID: source.id)
                                }
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
                    Button {
                        model.openImport()
                    } label: {
                        Label("Import from iPhone…", systemImage: "iphone")
                    }
                    .buttonStyle(.plain)
                    .help("Copy photos from a connected iPhone. Originals on the device stay put.")
                }
            }
            .listStyle(.sidebar)
            .font(StillroomFont.control)
            .scrollContentBackground(.hidden)
            .tint(Palette.accentColor)
            .background(SidebarSelectionStyle())

            footer
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .background(Palette.sidebarColor)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    AppMark(size: 18)
                    Text("Stillroom")
                        .font(StillroomFont.controlMedium)
                        .foregroundStyle(Palette.inkColor)
                }
                .padding(.trailing, 18)
            }
        }
    }

    private func row(
        _ title: String,
        systemImage: String,
        tag: SidebarSelection,
        tint: Color = Palette.inkColor
    ) -> some View {
        let selected = model.sidebarSelection == tag
        return Label(title, systemImage: systemImage)
            .foregroundStyle(selected ? Color.white : tint)
            .tag(tag)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Palette.accentColor : Color.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
            )
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
        VStack(alignment: .leading, spacing: 4) {
            switch model.footer {
            case .indexing(let progress):
                if let progress, progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(Palette.accentColor)
                    Text("Indexing \(Format.count(progress.completed)) of \(Format.count(progress.total))")
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.status)
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                        .lineLimit(2)
                }
                Text("Runs on this Mac")
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
            case .message(let text):
                Text(text)
                    .font(StillroomFont.caption)
                    .foregroundStyle(Palette.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .current:
                if model.counts.enabledTotal == 0, !model.sources.contains(where: { $0.kind == .folder }) {
                    Text("No folders added")
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                } else {
                    Text("Runs on this Mac")
                        .font(StillroomFont.caption)
                        .foregroundStyle(Palette.secondaryColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sidebar selection is gray once the detail is focused. The mockup keeps the violet pill.
private struct SidebarSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.flattenSelection(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.flattenSelection(from: nsView) }
    }

    private static func flattenSelection(from view: NSView) {
        guard let content = view.window?.contentView else { return }
        func walk(_ candidate: NSView) {
            if let table = candidate as? NSTableView {
                table.selectionHighlightStyle = .none
            }
            candidate.subviews.forEach(walk)
        }
        walk(content)
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
                    .foregroundStyle(Palette.secondaryColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.borderColor.opacity(0.45))
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
