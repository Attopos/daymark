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
    @State private var clusters: [MapCluster] = []
    @AppStorage("mapShowsSatellite") private var showsSatellite = false
    // One camera path instead of three: follow the user once location is
    // available, otherwise show the photos. Setting `.automatic` on every
    // appear and then jumping to a GPS fix made MapKit reload tiles twice.
    // The fallback must be a concrete region: `.automatic` re-frames whenever
    // the annotations change, and re-clustering on every camera change then
    // changes them again, looping forever.
    @State private var position: MapCameraPosition = .userLocation(
        followsHeading: false,
        fallback: .region(MapView.defaultRegion)
    )
    @State private var hasFramedPhotos = false

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    var body: some View {
        NavigationStack {
            Map(position: $position, interactionModes: .all, scope: mapScope) {
                UserAnnotation()

                ForEach(clusters) { cluster in
                    Annotation(cluster.title, coordinate: cluster.coordinate, anchor: .bottom) {
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
                refreshClusters()
            }
            // Swapping only the style keeps the same Map and annotations alive.
            // Satellite stays flat: realistic elevation on imagery streams 3D
            // mesh tiles, which is the heaviest thing MapKit can draw.
            .mapStyle(showsSatellite
                ? .hybrid(elevation: .flat)
                : .standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton(scope: mapScope)
                    .accessibilityLabel("Show Current Location")
                MapCompass()
                MapScaleView()
            }
            .mapScope(mapScope)
            .daymarkScreen()
            .daymarkNavigationTitle("Maps")
            .toolbarTitleDisplayMode(.inlineLarge)
            // On the map itself rather than in the nav bar: a toolbar button
            // floating over the Map never received its tap.
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showsSatellite.toggle()
                } label: {
                    Image(systemName: showsSatellite ? "map" : "globe.americas")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mapStyleToggle")
                .accessibilityLabel(showsSatellite ? "Show Standard Map" : "Show Satellite Map")
                .padding(16)
            }
            .onAppear {
                locationManager.requestAuthorizationIfNeeded()
                framePhotosIfNeeded()
                refreshClusters()
            }
            // Sync and backfill touch entries constantly; only re-cluster when
            // something the map actually draws (id, position, day) changed.
            .onChange(of: pinSignature) { _, _ in
                framePhotosIfNeeded()
                refreshClusters()
            }
            .alert("Location Access Needed", isPresented: locationAccessAlertBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Allow location access in Settings to center the map on your current position.")
            }
        }
    }

    private var pinSignature: Int {
        var combined = entries.count
        for entry in entries {
            var hasher = Hasher()
            hasher.combine(entry.id)
            hasher.combine(entry.latitude)
            hasher.combine(entry.longitude)
            hasher.combine(entry.day)
            combined = combined &+ hasher.finalize()
        }
        return combined
    }

    /// Once per view lifetime, swap the default fallback for the photos'
    /// bounding box so a user without location access still lands on their
    /// photos. Later visits keep wherever the camera was left.
    private func framePhotosIfNeeded() {
        guard !hasFramedPhotos else { return }
        let located = entries.compactMap(MapPin.init)
        guard !located.isEmpty else { return }
        hasFramedPhotos = true
        position = .userLocation(
            followsHeading: false,
            fallback: .camera(framingCamera(of: located))
        )
    }

    /// A camera that keeps every photo on screen. The realistic map style
    /// renders zoomed-out views as a globe, where a flat bounding box (degree
    /// region or Mercator rect) frames far too close and pushes distant photos
    /// over the horizon. So this works on the sphere: aim at the photos'
    /// spherical centroid and back off until the farthest one fits inside a
    /// conservative portrait field of view.
    private func framingCamera(of pins: [MapPin]) -> MapCamera {
        func unitVector(_ pin: MapPin) -> (x: Double, y: Double, z: Double) {
            let lat = pin.latitude * .pi / 180
            let lon = pin.longitude * .pi / 180
            return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        }

        let vectors = pins.map(unitVector)
        var x = vectors.reduce(0) { $0 + $1.x }
        var y = vectors.reduce(0) { $0 + $1.y }
        var z = vectors.reduce(0) { $0 + $1.z }
        let length = (x * x + y * y + z * z).squareRoot()
        if length > 1e-9 {
            x /= length; y /= length; z /= length
        } else {
            // Photos on opposite sides of the planet: any center will do.
            x = vectors[0].x; y = vectors[0].y; z = vectors[0].z
        }
        let center = CLLocationCoordinate2D(
            latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
            longitude: atan2(y, x) * 180 / .pi
        )

        // Largest angle (radians) between the center and any photo, padded so
        // annotations, which hang above their pin, clear the screen edges.
        let farthest = vectors
            .map { acos(min(max($0.x * x + $0.y * y + $0.z * z, -1), 1)) }
            .max() ?? 0
        let angle = min(farthest * 1.3 + 0.0002, .pi / 2.2)

        // Distance from the surface at which a point `angle` away sits within
        // `halfFieldOfView` of the view axis.
        let earthRadius = 6_371_000.0
        let halfFieldOfView = 12.0 * .pi / 180
        let distance = earthRadius * sin(angle) / tan(halfFieldOfView)
            - earthRadius * (1 - cos(angle))

        return MapCamera(centerCoordinate: center, distance: max(distance, 1_500))
    }

    private func refreshClusters() {
        let located = entries.compactMap(MapPin.init)
        guard !located.isEmpty else {
            clusters = []
            return
        }

        guard let region = visibleRegion else {
            // Before the first camera update, cluster across all photos coarsely
            // rather than dropping every individual pin onto the map.
            clusters = Self.clusterize(located, region: boundingRegion(of: located))
            return
        }

        let visible = located.filter { region.contains($0, marginFraction: 0.2) }
        clusters = Self.clusterize(visible, region: region)
    }

    /// Photos bucketed into a grid sized to the current zoom, so the map never
    /// draws more than a few dozen annotations at once. Buckets outside the
    /// visible region are culled; each visible bucket renders one representative
    /// thumbnail (with a +N badge when it stands in for several photos).
    private static func clusterize(
        _ pins: [MapPin],
        region: MKCoordinateRegion
    ) -> [MapCluster] {
        guard !pins.isEmpty else { return [] }

        // ~6 columns × ~12 rows of buckets across the visible region keeps cells
        // roughly one annotation-footprint apart, so pins don't visually overlap.
        // Steps snap to powers of two so panning and small zooms keep the same
        // bucket ids, letting MapKit reuse annotations instead of rebuilding all.
        let latStep = snappedStep(region.span.latitudeDelta / 12)
        let lonStep = snappedStep(region.span.longitudeDelta / 6)

        var buckets: [MapCluster.Key: (representative: MapPin, count: Int)] = [:]
        for pin in pins {
            let key = MapCluster.Key(
                row: Int((pin.latitude / latStep).rounded(.down)),
                col: Int((pin.longitude / lonStep).rounded(.down)),
                latStep: latStep
            )
            if let existing = buckets[key] {
                let newer = pin.day > existing.representative.day ? pin : existing.representative
                buckets[key] = (newer, existing.count + 1)
            } else {
                buckets[key] = (pin, 1)
            }
        }

        return buckets.map { key, bucket in
            MapCluster(
                id: key,
                coordinate: bucket.representative.coordinate,
                representative: bucket.representative.entry,
                title: bucket.representative.day.formatted(.dateTime.month(.abbreviated).day().year()),
                count: bucket.count
            )
        }
    }

    private static func snappedStep(_ raw: Double) -> Double {
        let clamped = max(raw, 1e-6)
        return pow(2, log2(clamped).rounded())
    }

    private func boundingRegion(of pins: [MapPin]) -> MKCoordinateRegion {
        let lats = pins.map(\.latitude)
        let lons = pins.map(\.longitude)
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

/// The few fields clustering needs, read off the SwiftData model once per
/// refresh instead of on every comparison.
struct MapPin {
    let entry: PhotoEntry
    let latitude: Double
    let longitude: Double
    let day: Date

    init?(_ entry: PhotoEntry) {
        guard let latitude = entry.latitude, let longitude = entry.longitude else { return nil }
        self.entry = entry
        self.latitude = latitude
        self.longitude = longitude
        self.day = entry.day
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MapCluster: Identifiable {
    struct Key: Hashable {
        let row: Int
        let col: Int
        let latStep: Double
    }

    let id: Key
    let coordinate: CLLocationCoordinate2D
    let representative: PhotoEntry
    let title: String
    let count: Int
}

extension MKCoordinateRegion {
    /// Whether the pin falls within this region, expanded by `marginFraction`
    /// on each side so pins just outside the edge aren't popped in and out.
    func contains(_ pin: MapPin, marginFraction: Double) -> Bool {
        let latReach = span.latitudeDelta * (0.5 + marginFraction)
        let lonReach = span.longitudeDelta * (0.5 + marginFraction)
        return abs(pin.latitude - center.latitude) <= latReach
            && abs(pin.longitude - center.longitude) <= lonReach
    }
}

struct ClusterAnnotation: View {
    let entry: PhotoEntry
    let count: Int

    var body: some View {
        EntryThumbnail(entry: entry) {
            ZStack {
                DaymarkPalette.recessed
                Image(systemName: "photo.stack")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(DaymarkPalette.photoMount, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DaymarkPalette.buttonText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(DaymarkPalette.buttonFill, in: Capsule())
                .overlay { Capsule().stroke(DaymarkPalette.photoMount, lineWidth: 1.5) }
                .offset(x: 7, y: -7)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

struct PhotoMapAnnotation: View {
    let entry: PhotoEntry

    var body: some View {
        VStack(spacing: 0) {
            EntryThumbnail(entry: entry) {
                ZStack {
                    DaymarkPalette.recessed

                    Image(systemName: "photo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DaymarkPalette.photoMount, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(DaymarkPalette.photoMount)
                .offset(y: -2)
        }
    }
}

#Preview {
    MapView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
