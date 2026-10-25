import CoreLocation
import MapKit

struct GeocodedLocation {
    let countryCode: String?
    let countryName: String?
    let city: String?
}

enum LocationGeocoder {
    static func reverseGeocode(
        latitude: Double,
        longitude: Double,
        preferredLocale: Locale
    ) async -> GeocodedLocation {
        let location = CLLocation(latitude: latitude, longitude: longitude)

        guard CLLocationCoordinate2DIsValid(location.coordinate) else {
            return GeocodedLocation(countryCode: nil, countryName: nil, city: nil)
        }

        if !Task.isCancelled,
           let request = MKReverseGeocodingRequest(location: location) {
            request.preferredLocale = preferredLocale
            if let mapItem = try? await request.mapItems.first {
                let address = mapItem.addressRepresentations
                let countryCode = normalizedCountryCode(address?.region?.identifier)
                let countryName = address?.regionName
                let city = address?.cityName ?? mapItem.name
                // MapKit answered in full, so the offline boundaries are not needed.
                if countryCode != nil, countryName != nil {
                    return GeocodedLocation(countryCode: countryCode, countryName: countryName, city: city)
                }
                let fallback = await offlineLocation(latitude: latitude, longitude: longitude, preferredLocale: preferredLocale)
                return GeocodedLocation(
                    countryCode: countryCode ?? fallback.countryCode,
                    countryName: countryName ?? fallback.countryName,
                    city: city
                )
            }
        }

        // Keep country flags available when MapKit cannot resolve an address.
        return await offlineLocation(latitude: latitude, longitude: longitude, preferredLocale: preferredLocale)
    }

    /// Country-only answer from the bundled boundaries. The first lookup parses
    /// an 11 MB file, so it runs off the main thread.
    private static func offlineLocation(
        latitude: Double,
        longitude: Double,
        preferredLocale: Locale
    ) async -> GeocodedLocation {
        let rawCode = await Task.detached(priority: .utility) {
            OfflineCountryLookup.countryCode(latitude: latitude, longitude: longitude)
        }.value
        let code = normalizedCountryCode(rawCode)
        let name = code.flatMap { preferredLocale.localizedString(forRegionCode: $0) }
        return GeocodedLocation(countryCode: code, countryName: name, city: nil)
    }

    /// ISO region codes, built once: `Locale.Region.isoRegions` allocates the
    /// whole list on every access, and flags call this for every visible tile.
    private static let isoRegionCodes = Set(Locale.Region.isoRegions.map(\.identifier))

    static func normalizedCountryCode(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 2,
              code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
              isoRegionCodes.contains(code) else {
            return nil
        }
        return code
    }
}
