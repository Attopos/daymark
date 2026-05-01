import CoreLocation
import MapKit
import SwiftUI

struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let onLocationSelected: (Double, Double, String?, String?, String?) -> Void

    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var city: String?
    @State private var countryCode: String?
    @State private var countryName: String?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var position: MapCameraPosition = .userLocation(
        followsHeading: false,
        fallback: .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        )
    )

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                MapReader { proxy in
                    Map(position: $position) {
                        if let coordinate = selectedCoordinate {
                            Marker("", coordinate: coordinate)
                        }
                        UserAnnotation()
                    }
                    .onTapGesture { screenPosition in
                        isSearching = false
                        if let coordinate = proxy.convert(screenPosition, from: .local) {
                            selectedCoordinate = coordinate
                            Task {
                                await reverseGeocode(coordinate)
                            }
                        }
                    }
                }

                if let displayName = locationDisplayName {
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("Choose Location")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, isPresented: $isSearching, prompt: "Search places")
            .searchSuggestions {
                ForEach(searchResults, id: \.self) { item in
                    Button {
                        selectSearchResult(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Unknown")
                                .font(.subheadline)
                            if let subtitle = item.addressRepresentations?.cityWithContext {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .task(id: searchText) {
                guard !searchText.isEmpty else {
                    searchResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await performSearch()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        guard let coordinate = selectedCoordinate else { return }
                        onLocationSelected(
                            coordinate.latitude,
                            coordinate.longitude,
                            city,
                            countryCode,
                            countryName
                        )
                        dismiss()
                    }
                    .disabled(selectedCoordinate == nil)
                }
            }
        }
    }

    private var locationDisplayName: String? {
        if let city, let countryCode {
            return "\(city), \(countryCode)"
        }
        if let city {
            return city
        }
        if let coordinate = selectedCoordinate {
            return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        }
        return nil
    }

    private func selectSearchResult(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        selectedCoordinate = coordinate
        position = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
        city = item.addressRepresentations?.cityName
        countryCode = item.addressRepresentations?.region?.identifier
        countryName = item.addressRepresentations?.regionName
        searchText = ""
    }

    private func performSearch() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else {
            searchResults = []
            return
        }
        searchResults = response.mapItems
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async {
        city = nil
        countryCode = nil
        countryName = nil

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        guard let mapItem = try? await request.mapItems.first else { return }

        city = mapItem.addressRepresentations?.cityName
        countryCode = mapItem.addressRepresentations?.region?.identifier
        countryName = mapItem.addressRepresentations?.regionName
    }
}
