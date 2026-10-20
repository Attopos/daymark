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

        let details = await LocationGeocoder.reverseGeocode(
            latitude: lat,
            longitude: lon,
            preferredLocale: .current
        )
        cache[key] = LocalizedLocation(
            city: details.city ?? entry.city,
            countryName: details.countryName ?? entry.countryName
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
