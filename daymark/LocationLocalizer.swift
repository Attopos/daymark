import CoreLocation
import MapKit

@MainActor
@Observable
final class LocationLocalizer {
    private var cache: [String: LocalizedLocation] = [:]

    private struct LocalizedLocation {
        let city: String?
        let countryName: String?
    }

    func localizedCity(for entry: PhotoEntry) -> String? {
        guard let lat = entry.latitude, let lon = entry.longitude else {
            return entry.city
        }
        return cache[cacheKey(lat: lat, lon: lon)]?.city ?? entry.city
    }

    func localizedCountryName(for entry: PhotoEntry) -> String? {
        guard let lat = entry.latitude, let lon = entry.longitude else {
            return entry.countryName
        }
        return cache[cacheKey(lat: lat, lon: lon)]?.countryName ?? entry.countryName
    }

    func localize(_ entry: PhotoEntry) async {
        guard let lat = entry.latitude, let lon = entry.longitude else { return }
        let key = cacheKey(lat: lat, lon: lon)
        guard cache[key] == nil else { return }

        if Locale.current.language.languageCode?.identifier == "en" {
            cache[key] = LocalizedLocation(city: entry.city, countryName: entry.countryName)
            return
        }

        let location = CLLocation(latitude: lat, longitude: lon)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            cache[key] = LocalizedLocation(city: entry.city, countryName: entry.countryName)
            return
        }
        request.preferredLocale = Locale.current
        guard let mapItem = try? await request.mapItems.first else {
            cache[key] = LocalizedLocation(city: entry.city, countryName: entry.countryName)
            return
        }

        let address = mapItem.addressRepresentations
        cache[key] = LocalizedLocation(
            city: address?.cityName ?? mapItem.name ?? entry.city,
            countryName: address?.regionName ?? entry.countryName
        )
    }

    func localize(_ entries: [PhotoEntry]) async {
        for entry in entries {
            await localize(entry)
        }
    }

    private func cacheKey(lat: Double, lon: Double) -> String {
        String(format: "%.4f,%.4f", lat, lon)
    }
}
