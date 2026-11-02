import AppKit
import PhotoIndex
import SwiftUI

struct GridView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.filterTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.inkColor)
                Spacer()
                Text(countLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if model.matchedCount == 0 {
                empty
            } else if let thumbnails = model.thumbnails {
                AssetCollection(
                    assets: model.assets,
                    side: model.thumbnailSide,
                    selectedID: model.selectedAssetID,
                    thumbnails: thumbnails,
                    selectedIDs: model.selectedAssets.map(\.id),
                    onSelect: { model.replaceSelection($0, focused: $1) },
                    onOpen: { model.open($0) },
                    onReveal: { model.reveal($0) },
                    onConvert: { model.showConvert($0) },
                    onPDF: { model.showPDF($0) }
                )
                .id(model.queryToken)
            }
        }
        .background(Palette.canvasColor)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(emptyTitle)
                .font(.title3.weight(.semibold))
            Text(emptyDetail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var countLine: String {
        var line = "\(Format.count(model.matchedCount)) · newest first"
        if model.selectedAssets.count > 1 {
            line += " · \(Format.count(model.selectedAssets.count)) selected"
        }
        return line
    }

    private var emptyTitle: String {
        if model.isIndexing { return "Indexing…" }
        if model.counts.enabledTotal == 0 { return "Nothing here yet" }
        return "Nothing in this view"
    }

    private var emptyDetail: String {
        if model.counts.enabledTotal == 0 {
            return "Turn on Screenshots, Downloads, or the Photos library, or add a folder. Stillroom reads files where they are."
        }
        return "Try another media type or source. The files themselves are unchanged."
    }
}

private struct DaySection {
    var id: String
    var title: String
    var assets: [Asset]
}

private struct AssetCollection: NSViewRepresentable {
    var assets: [Asset]
    var side: Double
    var selectedIDs: [String]
    var thumbnails: ThumbnailService
    var onSelect: ([Asset], Asset?) -> Void
    var onOpen: (Asset) -> Void
    var onReveal: (Asset) -> Void
    var onConvert: (Asset) -> Void
    var onPDF: (Asset) -> Void

    func makeNSView(context: Context) -> GridBrowser {
        let browser = GridBrowser()
        browser.thumbnails = thumbnails
        browser.onSelect = onSelect
        browser.onOpen = onOpen
        browser.onReveal = onReveal
        browser.onConvert = onConvert
        browser.onPDF = onPDF
        return browser
    }

    func updateNSView(_ browser: GridBrowser, context: Context) {
        browser.thumbnails = thumbnails
        browser.onSelect = onSelect
        browser.onOpen = onOpen
        browser.onReveal = onReveal
        browser.onConvert = onConvert
        browser.onPDF = onPDF
        browser.apply(assets: assets, side: CGFloat(side), selectedIDs: selectedIDs)
    }
}

private final class GridBrowser: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let scrollView = NSScrollView()
    let collectionView = NSCollectionView()
    let layout = NSCollectionViewFlowLayout()
    var sections: [DaySection] = []
    var rendered: [(String, String, Double)] = []
    var side: CGFloat = 144
    var selectedIDs: [String] = []
    var restoringSelection = false
    var thumbnails: ThumbnailService?
    var onSelect: (([Asset], Asset?) -> Void)?
    var onOpen: ((Asset) -> Void)?
    var onReveal: ((Asset) -> Void)?
    var onConvert: ((Asset) -> Void)?
    var onPDF: ((Asset) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 4, left: 16, bottom: 18, right: 16)
        layout.headerReferenceSize = NSSize(width: 200, height: 28)
        layout.itemSize = NSSize(width: side, height: side)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [Palette.canvas]
        collectionView.register(AssetItem.self, forItemWithIdentifier: AssetItem.reuseID)
        collectionView.register(
            DayHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: DayHeader.reuseID
        )

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.canvas
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(assets: [Asset], side: CGFloat, selectedIDs: [String]) {
        let next = assets.map { ($0.id, $0.contentHash ?? "", $0.duration ?? -1) }
        let contentChanged = next != rendered
        let sideChanged = abs(self.side - side) > 0.5
        self.selectedIDs = selectedIDs
        self.side = side
        if contentChanged || sideChanged {
            rendered = next
            sections = group(assets)
            layout.itemSize = NSSize(width: side, height: side)
            collectionView.reloadData()
            let photoIDs = assets.prefix(80).compactMap(\.photosLocalIdentifier)
            if !photoIDs.isEmpty {
                thumbnails?.preheat(localIdentifiers: Array(photoIDs), pixel: side * (window?.backingScaleFactor ?? 2))
            }
        }
        restoreSelection()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].assets.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: AssetItem.reuseID, for: indexPath) as! AssetItem
        let asset = sections[indexPath.section].assets[indexPath.item]
        item.side = side
        item.onOpen = { [weak self] in self?.onOpen?($0) }
        item.onReveal = { [weak self] in self?.onReveal?($0) }
        item.onConvert = { [weak self] in self?.onConvert?($0) }
        item.onPDF = { [weak self] in self?.onPDF?($0) }
        item.configure(asset, thumbnails: thumbnails, scale: window?.backingScaleFactor ?? 2)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: DayHeader.reuseID,
            for: indexPath
        ) as! DayHeader
        header.label.stringValue = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !restoringSelection else { return }
        publishSelection(focused: indexPaths.first)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !restoringSelection else { return }
        publishSelection(focused: nil)
    }

    private func publishSelection(focused indexPath: IndexPath?) {
        let assets = selectedAssetsInOrder()
        selectedIDs = assets.map(\.id)
        let hint = indexPath.flatMap { asset(at: $0) }
        let focused = hint.flatMap { item in assets.first { $0.id == item.id } } ?? assets.last
        onSelect?(assets, focused)
    }

    private func selectedAssetsInOrder() -> [Asset] {
        let chosen = Set(collectionView.selectionIndexPaths)
        var assets: [Asset] = []
        for (section, group) in sections.enumerated() {
            for (item, asset) in group.assets.enumerated() where chosen.contains(IndexPath(item: item, section: section)) {
                assets.append(asset)
            }
        }
        return assets
    }

    private func asset(at indexPath: IndexPath) -> Asset? {
        guard indexPath.section < sections.count, indexPath.item < sections[indexPath.section].assets.count else { return nil }
        return sections[indexPath.section].assets[indexPath.item]
    }

    private func restoreSelection() {
        var paths = Set<IndexPath>()
        for id in selectedIDs {
            if let indexPath = indexPath(for: id) {
                paths.insert(indexPath)
            }
        }
        restoringSelection = true
        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
        if !paths.isEmpty {
            collectionView.selectItems(at: paths, scrollPosition: [])
        }
        restoringSelection = false
    }

    private func indexPath(for id: String) -> IndexPath? {
        for (section, group) in sections.enumerated() {
            if let item = group.assets.firstIndex(where: { $0.id == id }) {
                return IndexPath(item: item, section: section)
            }
        }
        return nil
    }

    private func group(_ assets: [Asset]) -> [DaySection] {
        var sections: [DaySection] = []
        for asset in assets {
            let key = Format.dayKey(for: asset.createdAt)
            if sections.last?.id == key {
                sections[sections.count - 1].assets.append(asset)
            } else {
                sections.append(DaySection(id: key, title: Format.dayTitle(for: asset.createdAt), assets: [asset]))
            }
        }
        return sections
    }
}

private final class DayHeader: NSView, NSCollectionViewElement {
    static let reuseID = NSUserInterfaceItemIdentifier("DayHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class AssetItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("AssetItem")
    private let photo = FillImageView()
    private let badge = NSTextField(labelWithString: "")
    private var request: Task<Void, Never>?
    private var assetID: String?
    private var asset: Asset?
    var side: CGFloat = 144
    var onOpen: ((Asset) -> Void)?
    var onReveal: ((Asset) -> Void)?
    var onConvert: ((Asset) -> Void)?
    var onPDF: ((Asset) -> Void)?

    override func loadView() {
        let root = NSView()
        photo.wantsLayer = true
        photo.layer?.cornerRadius = 6
        photo.layer?.masksToBounds = true
        photo.layer?.backgroundColor = Palette.cell.cgColor
        photo.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        badge.isBezeled = false
        badge.isEditable = false
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        root.addSubview(photo)
        root.addSubview(badge)
        NSLayoutConstraint.activate([
            photo.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            photo.topAnchor.constraint(equalTo: root.topAnchor),
            photo.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        view = root
        view.wantsLayer = true
        view.menu = contextMenu()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(revealItem) {
            return asset?.filePath != nil
        }
        return true
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = Palette.accent.cgColor
            view.layer?.cornerRadius = 8
        }
    }

    func configure(_ asset: Asset, thumbnails: ThumbnailService?, scale: CGFloat) {
        self.asset = asset
        assetID = asset.id
        photo.image = nil
        if let duration = asset.duration, duration > 0,
           asset.mediaKind == .video || asset.mediaKind == .screenRecording {
            badge.stringValue = "  \(Format.duration(duration))  "
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        request?.cancel()
        let id = asset.id
        let side = side
        request = Task { @MainActor in
            let image = await thumbnails?.image(for: asset, pointSize: side, scale: scale, quality: .grid)
            guard !Task.isCancelled, self.assetID == id else { return }
            self.photo.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        photo.image = nil
        assetID = nil
        asset = nil
        badge.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let asset {
            onOpen?(asset)
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open", action: #selector(openItem), keyEquivalent: "")
        open.target = self
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealItem), keyEquivalent: "")
        reveal.target = self
        let convert = NSMenuItem(title: "Convert…", action: #selector(convertItem), keyEquivalent: "")
        convert.target = self
        let pdf = NSMenuItem(title: "Add to PDF…", action: #selector(pdfItem), keyEquivalent: "")
        pdf.target = self
        menu.addItem(open)
        menu.addItem(reveal)
        menu.addItem(.separator())
        menu.addItem(convert)
        menu.addItem(pdf)
        return menu
    }

    @objc private func convertItem() {
        guard let asset else { return }
        onConvert?(asset)
    }

    @objc private func pdfItem() {
        guard let asset else { return }
        onPDF?(asset)
    }

    @objc private func openItem() {
        guard let asset else { return }
        onOpen?(asset)
    }

    @objc private func revealItem() {
        guard let asset else { return }
        onReveal?(asset)
    }
}

private final class FillImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.cell.setFill()
        bounds.fill()
        guard let image else { return }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let draw = NSSize(width: size.width * scale, height: size.height * scale)
        let origin = NSPoint(x: (bounds.width - draw.width) / 2, y: (bounds.height - draw.height) / 2)
        image.draw(
            in: NSRect(origin: origin, size: draw),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
