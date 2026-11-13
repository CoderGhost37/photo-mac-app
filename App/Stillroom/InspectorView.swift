import MapKit
import PhotoIndex
import SwiftUI

struct InspectorView: View {
    var model: AppModel
    @State private var preview: NSImage?
    @State private var hits: [TextHit] = []
    @State private var labels: [String] = []

    var body: some View {
        Group {
            if let asset = model.selectedAsset {
                detail(asset)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "photo",
                    description: Text("Select a photo to see its details.")
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.canvasColor)
        .task(id: model.selectedAsset?.id) {
            preview = nil
            hits = []
            labels = []
            model.hoveredTextHitID = nil
            guard let asset = model.selectedAsset else { return }
            hits = model.textHits(for: asset)
            labels = model.sceneLabels(for: asset)
            guard let thumbnails = model.thumbnails else { return }
            preview = await thumbnails.image(for: asset, pointSize: 560, scale: 2, quality: .preview)
        }
    }

    private func detail(_ asset: Asset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Info")
                        .font(StillroomFont.section)
                        .foregroundStyle(Palette.inkColor)
                    Spacer()
                    Button {
                        model.inspectorVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.secondaryColor)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Hide Info")
                }
                previewBlock(asset)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.fileName(asset))
                        .font(StillroomFont.section)
                        .foregroundStyle(Palette.inkColor)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Text(Format.timestamp(asset.createdAt))
                        .font(StillroomFont.metadata)
                        .foregroundStyle(Palette.secondaryColor)
                    if model.selectedAssets.count > 1 {
                        Text("\(Format.count(model.selectedAssets.count)) selected")
                            .font(StillroomFont.caption)
                            .foregroundStyle(Palette.secondaryColor)
                    }
                }
                if cameraBlock(asset) != nil || exposureLine(asset) != nil {
                    section("Camera") {
                        if let camera = cameraBlock(asset) {
                            Label(camera.title, systemImage: "camera")
                                .font(StillroomFont.control)
                                .foregroundStyle(Palette.inkColor)
                            if let detail = camera.detail {
                                Text(detail)
                                    .font(StillroomFont.metadata)
                                    .foregroundStyle(Palette.secondaryColor)
                            }
                        }
                        if let exposure = exposureLine(asset) {
                            Text(exposure)
                                .font(StillroomFont.metadata)
                                .foregroundStyle(Palette.secondaryColor)
                        }
                    }
                }
                if summaryParts(asset) != nil {
                    section("File") {
                        if let line = summaryParts(asset) {
                            Text(line.primary)
                                .font(StillroomFont.control)
                                .foregroundStyle(Palette.inkColor)
                            if let secondary = line.secondary {
                                Text(secondary)
                                    .font(StillroomFont.metadata)
                                    .foregroundStyle(Palette.secondaryColor)
                            }
                        }
                    }
                }
                if displayedPlace(asset) != nil || asset.latitude != nil {
                    section("Location") {
                        if let place = displayedPlace(asset) {
                            Label(place, systemImage: "mappin.and.ellipse")
                                .font(StillroomFont.control)
                                .foregroundStyle(Palette.inkColor)
                        }
                        if let latitude = asset.latitude, let longitude = asset.longitude {
                            placeMap(latitude: latitude, longitude: longitude)
                        }
                    }
                }
                if asset.filePath != nil || asset.photosLocalIdentifier != nil {
                    section("File Path") {
                        if let path = asset.filePath {
                            Text(path)
                                .font(StillroomFont.path)
                                .foregroundStyle(Palette.inkColor)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                            Text("Original file · Read only")
                                .font(StillroomFont.caption)
                                .foregroundStyle(Palette.secondaryColor)
                        } else {
                            Text("Photos library")
                                .font(StillroomFont.path)
                                .foregroundStyle(Palette.inkColor)
                            Text("Original file · Read only")
                                .font(StillroomFont.caption)
                                .foregroundStyle(Palette.secondaryColor)
                        }
                    }
                }
                section("Source") {
                    HStack(alignment: .center) {
                        Text(sourceName(asset))
                            .font(StillroomFont.control)
                            .foregroundStyle(Palette.inkColor)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if asset.filePath != nil {
                            Button("Show in Finder") { model.reveal(asset) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Button("Open Photos") { model.openPhotosApp() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                let people = model.people(in: asset)
                if !people.isEmpty {
                    section("People") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(people) { cluster in
                                    personChip(cluster)
                                }
                            }
                        }
                    }
                }
                if !labels.isEmpty {
                    section("Keywords") {
                        Text(labels.joined(separator: ", "))
                            .font(StillroomFont.metadata)
                            .foregroundStyle(Palette.secondaryColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !hits.isEmpty {
                    section("Text") {
                        ForEach(hits) { hit in
                            Text(hit.text)
                                .font(StillroomFont.metadata)
                                .foregroundStyle(Palette.secondaryColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    model.hoveredTextHitID == hit.id
                                        ? Palette.accentColor.opacity(0.18)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .onHover { inside in
                                    if inside {
                                        model.hoveredTextHitID = hit.id
                                    } else if model.hoveredTextHitID == hit.id {
                                        model.hoveredTextHitID = nil
                                    }
                                }
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button(asset.isHidden ? "Unhide" : "Hide") {
                        let targets = model.selectedAssets.contains(where: { $0.id == asset.id }) ? model.selectedAssets : [asset]
                        model.setHidden(!asset.isHidden, assets: targets)
                    }
                    .buttonStyle(.borderless)
                    .font(StillroomFont.control)
                    if model.browse == .people, model.selectedSubjectID != nil {
                        Button("Remove from this group") {
                            model.removeSelectedFromSubject()
                        }
                        .buttonStyle(.borderless)
                        .font(StillroomFont.control)
                        .help("The photo stays in the library. It leaves this person or pet.")
                    }
                }
                .foregroundStyle(Palette.secondaryColor)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondaryColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewBlock(_ asset: Asset) -> some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background(Palette.borderColor.opacity(0.35))
            .overlay {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: Format.mediaSymbol(asset.mediaKind))
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.secondaryColor)
                }
            }
            .overlay {
                GeometryReader { geo in
                    if let preview,
                       let fitted = AspectFit.rect(
                        containerWidth: geo.size.width,
                        containerHeight: geo.size.height,
                        imageWidth: preview.size.width,
                        imageHeight: preview.size.height
                       ) {
                        boxes(in: fitted)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var matchedHits: [TextHit] {
        guard model.isSearching else { return [] }
        let tokens = model.searchPlan.highlightTokens
        return hits.filter { TextHighlight.matches(text: $0.text, tokens: tokens) }
    }

    private func boxes(in fitted: FittedRect) -> some View {
        let matched = matchedHits
        return ZStack(alignment: .topLeading) {
            ForEach(matched) { hit in
                let box = hit.box.flippedVertically().clamped()
                let emphasized = model.hoveredTextHitID == hit.id
                let quiet = model.hoveredTextHitID != nil && !emphasized
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Palette.accentColor.opacity(quiet ? 0.25 : 1), lineWidth: emphasized ? 2.5 : 1.5)
                    .background(Palette.accentColor.opacity(emphasized ? 0.28 : (quiet ? 0.04 : 0.14)))
                    .frame(
                        width: max(2, box.width * fitted.width),
                        height: max(2, box.height * fitted.height)
                    )
                    .offset(
                        x: fitted.x + box.x * fitted.width,
                        y: fitted.y + box.y * fitted.height
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func placeMap(latitude: Double, longitude: Double) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        return Map(position: .constant(.region(region))) {
            Annotation("", coordinate: coordinate) {
                Circle()
                    .fill(Palette.accentColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
        .mapStyle(.standard)
        .mapControls {}
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    private func personChip(_ cluster: SubjectClusterRecord) -> some View {
        let named = !cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 4) {
            FaceBubble(
                model: model,
                assetID: cluster.coverAssetID,
                box: cluster.coverBox,
                symbol: cluster.kind == .person ? "person.crop.circle" : "pawprint"
            )
            .frame(width: 44, height: 44)
            Text(named ? model.displayName(for: cluster) : "Add Name")
                .font(StillroomFont.caption)
                .foregroundStyle(named ? Palette.secondaryColor : Palette.accentColor)
                .lineLimit(1)
                .frame(width: 72)
        }
        .onTapGesture {
            if named {
                model.openSubject(cluster.id)
            } else {
                model.renameSubject(cluster)
            }
        }
    }

    private func summaryParts(_ asset: Asset) -> (primary: String, secondary: String?)? {
        var sizeLine: [String] = []
        if let size = Format.dimensions(width: asset.pixelWidth, height: asset.pixelHeight) {
            sizeLine.append(size)
        }
        if let megapixels = Format.megapixels(width: asset.pixelWidth, height: asset.pixelHeight) {
            sizeLine.append(megapixels)
        }
        var fileLine: [String] = []
        if let format = Format.fileExtension(asset) {
            fileLine.append(format)
        }
        if let fileSize = asset.fileSize {
            fileLine.append(Format.bytes(fileSize))
        }
        if let duration = asset.duration, duration > 0 {
            fileLine.append(Format.duration(duration))
        }
        let primary = sizeLine.joined(separator: " · ")
        let secondary = fileLine.joined(separator: " · ")
        if primary.isEmpty && secondary.isEmpty { return nil }
        if primary.isEmpty { return (secondary, nil) }
        return (primary, secondary.isEmpty ? nil : secondary)
    }

    private func displayedPlace(_ asset: Asset) -> String? {
        TimelineGrouping.displayPlace(for: asset)
    }

    private func sourceName(_ asset: Asset) -> String {
        model.sources.first { $0.id == asset.sourceID }?.displayName ?? "Library"
    }

    private func cameraBlock(_ asset: Asset) -> (title: String, detail: String?)? {
        let camera = [asset.cameraMake, asset.cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let lens = asset.lensModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let focal = Format.focalLength(asset.focalLength)
        var detailParts = [String]()
        if !lens.isEmpty { detailParts.append(lens) }
        if let focal { detailParts.append(focal) }
        let detail = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
        if camera.isEmpty && detail == nil { return nil }
        return (camera.isEmpty ? (detail ?? "") : camera, camera.isEmpty ? nil : detail)
    }

    private func exposureLine(_ asset: Asset) -> String? {
        let parts = [
            Format.aperture(asset.aperture),
            Format.shutter(asset.shutterSpeed),
            asset.iso.map { "ISO \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
