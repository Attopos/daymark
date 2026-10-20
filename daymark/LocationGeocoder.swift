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

        // Keep country flags available when MapKit cannot resolve an address.
        let offlineCode = normalizedCountryCode(OfflineCountryLookup.countryCode(
            latitude: latitude, longitude: longitude
        ))
        let offlineName = offlineCode.flatMap { preferredLocale.localizedString(forRegionCode: $0) }
        let fallback = GeocodedLocation(countryCode: offlineCode, countryName: offlineName, city: nil)

        guard !Task.isCancelled,
              let request = MKReverseGeocodingRequest(location: location) else {
            return fallback
        }
        request.preferredLocale = preferredLocale
        guard let mapItem = try? await request.mapItems.first else {
            return fallback
        }

        let address = mapItem.addressRepresentations
        let regionIdentifier = address?.region?.identifier
        return GeocodedLocation(
            countryCode: normalizedCountryCode(regionIdentifier) ?? fallback.countryCode,
            countryName: address?.regionName ?? fallback.countryName,
            city: address?.cityName ?? mapItem.name
        )
    }

    static func normalizedCountryCode(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 2,
              code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
              Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else {
            return nil
        }
        return code
    }
}
