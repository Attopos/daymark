import Combine
import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct MapView: View {
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]
    @Namespace private var mapScope
    @StateObject private var locationManager = DaymarkLocationManager()
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var position: MapCameraPosition = .userLocation(
        followsHeading: false,
        fallback: .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            )
        )
    )
    var body: some View {
        NavigationStack {
            Map(position: $position, interactionModes: .all, scope: mapScope) {
                UserAnnotation()

                ForEach(clusters) { cluster in
                    Annotation(
                        daymarkTitle(for: cluster.representative),
                        coordinate: cluster.coordinate,
                        anchor: .bottom
                    ) {
                        if cluster.count == 1 {
                            PhotoMapAnnotation(entry: cluster.representative)
                        } else {
                            ClusterAnnotation(entry: cluster.representative, count: cluster.count)
                                .onTapGesture { zoomIn(on: cluster) }
                        }
                    }
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton(scope: mapScope)
                    .accessibilityLabel("Show Current Location")
                MapCompass()
                MapScaleView()
            }
            .mapScope(mapScope)
            .navigationTitle("Maps")
            .toolbarTitleDisplayMode(.inlineLarge)
            .onAppear {
                locationManager.requestAuthorizationIfNeeded()
                focusMapIfNeeded()
            }
            .onChange(of: locatedEntries.count) { _, _ in
                focusMapIfNeeded()
            }
            .onReceive(locationManager.$currentRegion.compactMap { $0 }) { region in
                position = .region(region)
            }
            .alert("Location Access Needed", isPresented: locationAccessAlertBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Allow location access in Settings to center the map on your current position.")
            }
        }
    }

    private var locatedEntries: [PhotoEntry] {
        entries.filter { $0.latitude != nil && $0.longitude != nil }
    }

    /// Photos bucketed into a grid sized to the current zoom, so the map never
    /// draws more than a few dozen annotations at once. Buckets outside the
    /// visible region are culled; each visible bucket renders one representative
    /// thumbnail (with a +N badge when it stands in for several photos).
    private var clusters: [MapCluster] {
        let located = locatedEntries
        guard !located.isEmpty else { return [] }

        guard let region = visibleRegion else {
            // Before the first camera update, cluster across all photos coarsely
            // rather than dropping every individual pin onto the map.
            return Self.clusterize(located, region: boundingRegion(of: located))
        }

        let visible = located.filter { region.contains($0, marginFraction: 0.2) }
        return Self.clusterize(visible, region: region)
    }

    private static func clusterize(
        _ entries: [PhotoEntry],
        region: MKCoordinateRegion
    ) -> [MapCluster] {
        guard !entries.isEmpty else { return [] }

        // ~6 columns × ~12 rows of buckets across the visible region keeps cells
        // roughly one annotation-footprint apart, so pins don't visually overlap.
        let latStep = max(region.span.latitudeDelta / 12, 1e-6)
        let lonStep = max(region.span.longitudeDelta / 6, 1e-6)

        var buckets: [String: [PhotoEntry]] = [:]
        for entry in entries {
            guard let lat = entry.latitude, let lon = entry.longitude else { continue }
            let row = (lat / latStep).rounded(.down)
            let col = (lon / lonStep).rounded(.down)
            buckets["\(row):\(col)", default: []].append(entry)
        }

        return buckets.map { key, group in
            let representative = group.max { $0.day < $1.day } ?? group[0]
            return MapCluster(
                id: key,
                coordinate: CLLocationCoordinate2D(
                    latitude: representative.latitude ?? 0,
                    longitude: representative.longitude ?? 0
                ),
                representative: representative,
                count: group.count
            )
        }
    }

    private func boundingRegion(of entries: [PhotoEntry]) -> MKCoordinateRegion {
        let lats = entries.compactMap(\.latitude)
        let lons = entries.compactMap(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.3, 0.01),
                longitudeDelta: max((maxLon - minLon) * 1.3, 0.01)
            )
        )
    }

    private func zoomIn(on cluster: MapCluster) {
        let currentSpan = visibleRegion?.span
            ?? MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        let newSpan = MKCoordinateSpan(
            latitudeDelta: max(currentSpan.latitudeDelta * 0.35, 0.002),
            longitudeDelta: max(currentSpan.longitudeDelta * 0.35, 0.002)
        )
        withAnimation(.easeInOut) {
            position = .region(
                MKCoordinateRegion(center: cluster.coordinate, span: newSpan)
            )
        }
    }

    private func daymarkTitle(for entry: PhotoEntry) -> String {
        entry.day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func focusMapIfNeeded() {
        guard !locatedEntries.isEmpty else { return }
        position = .automatic
    }

    private var locationAccessAlertBinding: Binding<Bool> {
        Binding(
            get: { locationManager.showsPermissionAlert },
            set: { locationManager.showsPermissionAlert = $0 }
        )
    }
}

final class DaymarkLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentRegion: MKCoordinateRegion?
    @Published var showsPermissionAlert = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            showsPermissionAlert = true
        case .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            break
        }
    }

    func requestCurrentLocation() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            showsPermissionAlert = true
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            showsPermissionAlert = false
            manager.requestLocation()
        case .restricted, .denied:
            showsPermissionAlert = true
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }

        currentRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError, clError.code == .denied else { return }
        showsPermissionAlert = true
    }
}

struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let representative: PhotoEntry
    let count: Int
}

extension MKCoordinateRegion {
    /// Whether the entry falls within this region, expanded by `marginFraction`
    /// on each side so pins just outside the edge aren't popped in and out.
    func contains(_ entry: PhotoEntry, marginFraction: Double) -> Bool {
        guard let lat = entry.latitude, let lon = entry.longitude else { return false }
        let latReach = span.latitudeDelta * (0.5 + marginFraction)
        let lonReach = span.longitudeDelta * (0.5 + marginFraction)
        return abs(lat - center.latitude) <= latReach
            && abs(lon - center.longitude) <= lonReach
    }
}

struct ClusterAnnotation: View {
    let entry: PhotoEntry
    let count: Int

    var body: some View {
        EntryThumbnail(entry: entry) {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: "photo.stack")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor, in: Capsule())
                .overlay { Capsule().stroke(Color.white, lineWidth: 1.5) }
                .offset(x: 7, y: -7)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

struct PhotoMapAnnotation: View {
    let entry: PhotoEntry

    var body: some View {
        VStack(spacing: 0) {
            EntryThumbnail(entry: entry) {
                ZStack {
                    Color(.secondarySystemBackground)

                    Image(systemName: "photo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .offset(y: -2)
        }
    }
}

#Preview {
    MapView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
