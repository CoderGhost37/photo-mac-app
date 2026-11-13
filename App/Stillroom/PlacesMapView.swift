import MapKit
import PhotoIndex
import SwiftUI

struct PlacesMapView: View {
    var model: AppModel
    var onSelect: ([String]) -> Void
    var onFocus: ([String]) -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var span = MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 160)
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 160)
    )
    @State private var fitted = false

    var body: some View {
        Map(position: $position) {
            ForEach(visibleClusters) { cluster in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)) {
                    clusterMark(cluster)
                }
            }
        }
        .mapStyle(model.mapUsesSatellite ? .imagery : .standard)
        .mapControls {}
        .onMapCameraChange(frequency: .onEnd) { context in
            span = context.region.span
            region = context.region
        }
        .onAppear(perform: fitIfNeeded)
        .onChange(of: model.mapPoints.map(\.id)) { _, _ in
            fitted = false
            fitIfNeeded()
        }
        .onChange(of: model.mapFitToken) { _, _ in
            fitted = false
            fitIfNeeded()
        }
        .overlay(alignment: .bottomTrailing) {
            zoomButtons
                .padding(16)
                .padding(.bottom, model.placeMemberIDs == nil ? 0 : 168)
        }
    }

    private var clusters: [MapCluster] {
        MapGrid.cluster(model.mapPoints, latitudeSpan: span.latitudeDelta, longitudeSpan: span.longitudeDelta)
    }

    private var visibleClusters: [MapCluster] {
        let query = model.placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clusters }
        return clusters.filter { placeName(for: $0).localizedCaseInsensitiveContains(query) }
    }

    private func fitIfNeeded() {
        guard !fitted, let fittedRegion = MapGrid.fittingSpan(for: model.mapPoints) else { return }
        fitted = true
        let next = MKCoordinateSpan(latitudeDelta: fittedRegion.latitudeDelta, longitudeDelta: fittedRegion.longitudeDelta)
        span = next
        let coordinate = CLLocationCoordinate2D(latitude: fittedRegion.centerLatitude, longitude: fittedRegion.centerLongitude)
        region = MKCoordinateRegion(center: coordinate, span: next)
        position = .region(region)
    }

    private func placeName(for cluster: MapCluster) -> String {
        var counts: [String: Int] = [:]
        for id in cluster.memberIDs {
            guard let asset = model.asset(id: id), let place = TimelineGrouping.displayPlace(for: asset) else { continue }
            counts[place, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? "Place"
    }

    private func isSelected(_ cluster: MapCluster) -> Bool {
        guard let selected = model.placeMemberIDs, !selected.isEmpty else { return false }
        let selectedSet = Set(selected)
        let overlap = Set(cluster.memberIDs).intersection(selectedSet).count
        guard overlap > 0 else { return false }
        let best = visibleClusters.reduce(into: 0) { partial, candidate in
            partial = max(partial, Set(candidate.memberIDs).intersection(selectedSet).count)
        }
        return overlap == best
    }

    @ViewBuilder
    private func clusterMark(_ cluster: MapCluster) -> some View {
        let name = placeName(for: cluster)
        let lines = split(name)
        if isSelected(cluster) {
            VStack(alignment: .leading, spacing: 8) {
                callout(cluster, title: lines.0, subtitle: lines.1)
                thumbnail(cluster)
            }
        } else {
            Button {
                onSelect(cluster.memberIDs)
            } label: {
                Text(Format.count(cluster.count))
                    .font(StillroomFont.controlMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help(cluster.count == 1 ? "Show this photo" : "Show \(cluster.count) photos here")
        }
    }

    private func callout(_ cluster: MapCluster, title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(StillroomFont.section)
                .foregroundStyle(Palette.inkColor)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(StillroomFont.metadata)
                    .foregroundStyle(Palette.secondaryColor)
                    .lineLimit(1)
            }
            Text(Format.countPhrase(cluster.count, singular: "photo", plural: "photos"))
                .font(StillroomFont.caption)
                .foregroundStyle(Palette.secondaryColor)
            Button("View Photos") {
                onFocus(cluster.memberIDs)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentColor)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func thumbnail(_ cluster: MapCluster) -> some View {
        PlaceThumb(model: model, assetID: cluster.memberIDs.first)
            .frame(width: 92, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.accentColor, lineWidth: 2)
            }
            .overlay(alignment: .topLeading) {
                Text(Format.count(cluster.count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.accentColor, in: RoundedRectangle(cornerRadius: 5))
                    .padding(4)
            }
            .onTapGesture {
                onSelect(cluster.memberIDs)
            }
    }

    private func split(_ name: String) -> (String, String?) {
        let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[1].isEmpty { return (parts[0], parts[1]) }
        return (name, nil)
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            zoomButton("plus") { zoom(by: 0.5) }
            Divider().frame(width: 28)
            zoomButton("minus") { zoom(by: 2) }
        }
        .background(Palette.raisedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.borderColor)
        }
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 28)
                .foregroundStyle(Palette.inkColor)
        }
        .buttonStyle(.plain)
    }

    private func zoom(by factor: Double) {
        var next = region
        next.span.latitudeDelta = min(120, max(0.01, next.span.latitudeDelta * factor))
        next.span.longitudeDelta = min(120, max(0.01, next.span.longitudeDelta * factor))
        span = next.span
        region = next
        position = .region(next)
    }
}

private struct PlaceThumb: View {
    var model: AppModel
    var assetID: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.borderColor.opacity(0.4)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: assetID) {
            image = nil
            guard let assetID, let asset = model.asset(id: assetID) else { return }
            image = await model.thumbnails?.image(for: asset, pointSize: 180, scale: 2, quality: .grid)
        }
    }
}
