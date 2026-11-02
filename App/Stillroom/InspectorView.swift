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
                    systemImage: "photo.on.rectangle",
                    description: Text("Select a photo to see its details.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Form {
            Section {
                previewBlock(asset)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: asset))
                        .font(.headline)
                        .textSelection(.enabled)
                    if model.selectedAssets.count > 1 {
                        Text("\(Format.count(model.selectedAssets.count)) selected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                labeled("Date", Format.timestamp(asset.createdAt))
                if let camera = cameraLens(asset) {
                    labeled("Camera", camera)
                }
                if let summary = summaryLine(asset) {
                    labeled("Info", summary)
                }
                if let exposure = exposureLine(asset) {
                    labeled("Exposure", exposure)
                }
                if let place = displayedPlace(asset) {
                    labeled("Place", place)
                }
                if let coordinate = Format.coordinate(latitude: asset.latitude, longitude: asset.longitude) {
                    labeled("Location", coordinate)
                }
                if let path = asset.filePath {
                    labeled("Path", path)
                } else if asset.photosLocalIdentifier != nil {
                    labeled("Where", "Photos library")
                }
            }
            if let latitude = asset.latitude, let longitude = asset.longitude {
                Section {
                    placeMap(latitude: latitude, longitude: longitude)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }
            let people = model.people(in: asset)
            if !people.isEmpty {
                Section("People") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(people) { cluster in
                                personChip(cluster)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 78)
                }
            }
            if !labels.isEmpty {
                Section("Keywords") {
                    Text(labels.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !hits.isEmpty {
                Section("Text found") {
                    ForEach(hits) { hit in
                        Text(hit.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                model.hoveredTextHitID == hit.id
                                    ? Color.accentColor.opacity(0.18)
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
            Section {
                actionButtons(asset)
            }
        }
        .formStyle(.grouped)
        .font(.callout)
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(label)
                .font(.callout)
        }
    }

    private func previewBlock(_ asset: Asset) -> some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let imageSize = preview?.size ?? CGSize(width: 16, height: 10)
                    let fitted = AspectFit.rect(
                        containerWidth: geo.size.width,
                        containerHeight: geo.size.height,
                        imageWidth: imageSize.width,
                        imageHeight: imageSize.height
                    )
                    ZStack(alignment: .topLeading) {
                        Color.primary.opacity(0.04)
                        if let preview, let fitted {
                            Image(nsImage: preview)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                                .position(x: fitted.x + fitted.width / 2, y: fitted.y + fitted.height / 2)
                            boxes(in: fitted)
                        } else {
                            Image(systemName: Format.mediaSymbol(asset.mediaKind))
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .stroke(Color.accentColor.opacity(quiet ? 0.25 : 1), lineWidth: emphasized ? 2.5 : 1.5)
                    .background(Color.accentColor.opacity(emphasized ? 0.28 : (quiet ? 0.04 : 0.14)))
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
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
        .mapControls {}
        .frame(height: 140)
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
                .font(.caption)
                .foregroundStyle(named ? .secondary : .tertiary)
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

    private func actionButtons(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Open") { model.open(asset) }
                if asset.filePath != nil {
                    Button("Show in Finder") { model.reveal(asset) }
                } else {
                    Button("Open Photos") { model.openPhotosApp() }
                }
                Button(asset.isFavorite ? "Unfavorite" : "Favorite") {
                    model.setFavorite(!asset.isFavorite, assets: model.selectedAssets.contains(where: { $0.id == asset.id }) ? model.selectedAssets : [asset])
                }
            }
            HStack(spacing: 8) {
                Button("Convert") { model.openConvert() }
                Button("PDF") { model.openPDF() }
                Button(asset.isHidden ? "Unhide" : "Hide") {
                    model.setHidden(!asset.isHidden, assets: model.selectedAssets.contains(where: { $0.id == asset.id }) ? model.selectedAssets : [asset])
                }
                .help(asset.isHidden ? "Show this again in the library. The file is not changed." : "Hide this from the library, search, map, and highlights. The file is not changed.")
            }
            if model.browse == .people, model.selectedSubjectID != nil {
                Button("Remove from this group") {
                    model.removeSelectedFromSubject()
                }
                .help("The photo stays in the library. It leaves this person or pet.")
            }
        }
        .controlSize(.small)
    }

    private func summaryLine(_ asset: Asset) -> String? {
        var parts: [String] = []
        if let size = Format.dimensions(width: asset.pixelWidth, height: asset.pixelHeight) {
            parts.append(size)
        }
        if let fileSize = asset.fileSize {
            parts.append(Format.bytes(fileSize))
        }
        if let format = fileFormat(asset) {
            parts.append(format)
        }
        if let duration = asset.duration, duration > 0 {
            parts.append(Format.duration(duration))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fileFormat(_ asset: Asset) -> String? {
        if let path = asset.filePath {
            let ext = URL(fileURLWithPath: path).pathExtension
            return ext.isEmpty ? nil : ext.uppercased()
        }
        return nil
    }

    private func displayedPlace(_ asset: Asset) -> String? {
        let stored = asset.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let geocoded = asset.geocodedPlace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty && !geocoded.isEmpty && stored.caseInsensitiveCompare(geocoded) != .orderedSame {
            return "\(stored) · \(geocoded)"
        }
        if !stored.isEmpty { return stored }
        if !geocoded.isEmpty { return geocoded }
        return nil
    }

    private func title(for asset: Asset) -> String {
        if let path = asset.filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return Format.mediaTitle(asset.mediaKind)
    }

    private func cameraLens(_ asset: Asset) -> String? {
        let camera = [asset.cameraMake, asset.cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let lens = asset.lensModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [camera, lens].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func exposureLine(_ asset: Asset) -> String? {
        let parts = [
            Format.aperture(asset.aperture),
            Format.shutter(asset.shutterSpeed),
            asset.iso.map { "ISO \($0)" },
            Format.focalLength(asset.focalLength)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
