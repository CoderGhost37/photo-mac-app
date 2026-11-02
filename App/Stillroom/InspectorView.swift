import AppKit
import PhotoIndex
import SwiftUI

struct InspectorView: View {
    var model: AppModel
    @State private var preview: NSImage?
    @State private var hits: [TextHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let asset = model.selectedAsset {
                previewBlock(asset)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(title(for: asset))
                            .font(.headline)
                            .foregroundStyle(Palette.inkColor)
                            .textSelection(.enabled)
                        if model.selectedAssets.count > 1 {
                            Text("\(Format.count(model.selectedAssets.count)) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        phrases
                        facts(asset)
                        actions(asset)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inspector")
                        .font(.headline)
                    Text("Select a photo or video to see when it was made, how large it is, and where it lives.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                Spacer()
            }
        }
        .background(Palette.inspectorColor)
        .task(id: model.selectedAsset?.id) {
            preview = nil
            hits = []
            model.hoveredTextHitID = nil
            guard let asset = model.selectedAsset else { return }
            hits = model.textHits(for: asset)
            guard let thumbnails = model.thumbnails else { return }
            preview = await thumbnails.image(for: asset, pointSize: 560, scale: 2, quality: .preview)
        }
    }

    private var matchedHits: [TextHit] {
        guard model.isSearching else { return [] }
        let tokens = model.searchPlan.highlightTokens
        return hits.filter { TextHighlight.matches(text: $0.text, tokens: tokens) }
    }

    private var phrases: some View {
        let matched = matchedHits
        return Group {
            if !matched.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text in this picture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(matched) { hit in
                        Text(hit.text)
                            .font(.callout)
                            .foregroundStyle(Palette.inkColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
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
        }
    }

    private func previewBlock(_ asset: Asset) -> some View {
        GeometryReader { geo in
            let imageSize = preview?.size ?? CGSize(width: 1, height: 1)
            let fitted = AspectFit.rect(
                containerWidth: geo.size.width,
                containerHeight: geo.size.height,
                imageWidth: imageSize.width,
                imageHeight: imageSize.height
            )
            ZStack(alignment: .topLeading) {
                Palette.canvasColor
                if let preview, let fitted {
                    Image(nsImage: preview)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.x + fitted.width / 2, y: fitted.y + fitted.height / 2)
                    boxes(in: fitted)
                } else {
                    Image(systemName: Format.mediaSymbol(asset.mediaKind))
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .background(Palette.canvasColor)
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

    private func facts(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Kind", Format.mediaTitle(asset.mediaKind))
            fact("Created", Format.timestamp(asset.createdAt))
            fact("Modified", Format.timestamp(asset.modifiedAt))
            if let size = Format.dimensions(width: asset.pixelWidth, height: asset.pixelHeight) {
                fact("Dimensions", size)
            }
            if let fileSize = asset.fileSize {
                fact("File size", Format.bytes(fileSize))
            }
            if let duration = asset.duration, duration > 0 {
                fact("Duration", Format.duration(duration))
            }
            if let camera = cameraLine(asset) {
                fact("Camera", camera)
            }
            if let lens = asset.lensModel {
                fact("Lens", lens)
            }
            if let exposure = exposureLine(asset) {
                fact("Exposure", exposure)
            }
            if let place = displayedPlace(asset) {
                fact("Place", place)
            }
            if let place = Format.coordinate(latitude: asset.latitude, longitude: asset.longitude) {
                fact("Location", place)
            }
            if let path = asset.filePath {
                fact("Path", path)
            } else if asset.photosLocalIdentifier != nil {
                fact("Where", "Photos library")
            }
        }
    }

    private func actions(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Open") { model.open(asset) }
                if asset.filePath != nil {
                    Button("Reveal in Finder") { model.reveal(asset) }
                } else {
                    Button("Open Photos") { model.openPhotosApp() }
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

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(Palette.inkColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(for asset: Asset) -> String {
        if let path = asset.filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return Format.mediaTitle(asset.mediaKind)
    }

    private func cameraLine(_ asset: Asset) -> String? {
        let parts = [asset.cameraMake, asset.cameraModel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
