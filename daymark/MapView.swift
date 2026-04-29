import MapKit
import SwiftData
import SwiftUI

struct MapView: View {
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]
    @Namespace private var mapScope
    private let photoStore = PhotoStore()
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
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .mapScope(mapScope)
            .navigationTitle("Maps")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                focusMapIfNeeded()
            }
            .onChange(of: locatedEntries.count) { _, _ in
                focusMapIfNeeded()
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
