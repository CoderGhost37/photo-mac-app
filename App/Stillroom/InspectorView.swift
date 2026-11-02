import AppKit
import PhotoIndex
import SwiftUI

struct InspectorView: View {
    var model: AppModel
    @State private var preview: NSImage?

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
            guard let asset = model.selectedAsset, let thumbnails = model.thumbnails else { return }
            preview = await thumbnails.image(for: asset, pointSize: 560, scale: 2, quality: .preview)
        }
    }

    private func previewBlock(_ asset: Asset) -> some View {
        ZStack {
            Palette.canvasColor
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                Image(systemName: Format.mediaSymbol(asset.mediaKind))
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
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
            }
        }
        .controlSize(.small)
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
