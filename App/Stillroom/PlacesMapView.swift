import MapKit
import PhotoIndex
import SwiftUI

struct PlacesMapView: View {
    var points: [GeoPoint]
    var onSelect: ([String]) -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var span = MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 160)
    @State private var fitted = false

    var body: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)) {
                    Button {
                        onSelect(cluster.memberIDs)
                    } label: {
                        pin(count: cluster.count)
                    }
                    .buttonStyle(.plain)
                    .help(cluster.count == 1 ? "Show this photo" : "Show \(cluster.count) photos here")
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            span = context.region.span
        }
        .onAppear(perform: fitIfNeeded)
        .onChange(of: points.map(\.id)) { _, _ in
            fitIfNeeded()
        }
    }

    private var clusters: [MapCluster] {
        MapGrid.cluster(points, latitudeSpan: span.latitudeDelta, longitudeSpan: span.longitudeDelta)
    }

    private func fitIfNeeded() {
        guard !fitted, let region = MapGrid.fittingSpan(for: points) else { return }
        fitted = true
        let next = MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)
        span = next
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.centerLatitude, longitude: region.centerLongitude),
            span: next
        ))
    }

    private func pin(count: Int) -> some View {
        Text(count > 1 ? "\(count)" : "")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: count > 1 ? 32 : 16, minHeight: count > 1 ? 32 : 16)
            .background(Palette.accentColor)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
