import Combine
import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct MapView: View {
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]
    @Namespace private var mapScope
    private let photoStore = PhotoStore()
    @StateObject private var locationManager = DaymarkLocationManager()
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

                ForEach(locatedEntries) { entry in
                    Annotation(daymarkTitle(for: entry), coordinate: coordinate(for: entry), anchor: .bottom) {
                        PhotoMapAnnotation(image: photoStore.thumbnail(for: entry))
                    }
                }
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

    private func coordinate(for entry: PhotoEntry) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: entry.latitude ?? 0, longitude: entry.longitude ?? 0)
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

private final class DaymarkLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
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

private struct PhotoMapAnnotation: View {
    let image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
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
