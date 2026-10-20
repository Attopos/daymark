import XCTest
import SwiftData
@testable import Daymark_Journal

@MainActor
final class LocationTests: XCTestCase {
    func testOfflineCountriesFromCoordinatesWhenGeocodingIsUnavailable() {
        for (latitude, longitude, code) in [
            (35.6762, 139.6503, "JP"), (48.8566, 2.3522, "FR"),
            (37.7749, -122.4194, "US"), (31.2304, 121.4737, "CN"),
            (51.5074, -0.1278, "GB"), (-33.8688, 151.2093, "AU"),
            (1.3521, 103.8198, "SG"), (22.3193, 114.1694, "HK"),
            (22.1935, 113.5439, "MO"), (25.0330, 121.5654, "TW"),
            (21.3099, -157.8581, "US"), (-18.1416, 178.4419, "FJ")
        ] {
            XCTAssertEqual(OfflineCountryLookup.countryCode(latitude: latitude, longitude: longitude), code)
        }
    }

    func testOfflineLookupDoesNotGuessCountriesForOceanOrInvalidCoordinates() {
        XCTAssertNil(OfflineCountryLookup.countryCode(latitude: 0, longitude: -140))
        XCTAssertNil(OfflineCountryLookup.countryCode(latitude: 200, longitude: 300))
    }

    func testFlagsForInternationalLocations() {
        for (code, flag) in [
            ("CN", "🇨🇳"), ("US", "🇺🇸"), ("JP", "🇯🇵"), ("FR", "🇫🇷"),
            ("GB", "🇬🇧"), ("HK", "🇭🇰"), ("MO", "🇲🇴"), ("TW", "🇹🇼"),
            (" sg \n", "🇸🇬")
        ] {
            XCTAssertEqual(PhotoEntry(day: .now, countryCode: code).flagEmoji, flag, code)
        }
    }

    func testMalformedCountryCodesDoNotProduceFlags() {
        for code in ["", "USA", "US-CA", "12", "中囯", "ÉÉ", "ZZ", "🌏"] {
            XCTAssertNil(PhotoEntry(day: .now, countryCode: code).flagEmoji, code)
        }
        XCTAssertNil(PhotoEntry(day: .now).flagEmoji)
    }

    func testBackfillRepairsAndPersistsLegacyInternationalEntry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(day: .now, latitude: 35.6762, longitude: 139.6503,
                               countryCode: "JPN", countryName: "Japan", city: "Tokyo")
        context.insert(entry)
        try context.save()

        await PhotoStore().backfillLocationDetails(for: [entry], in: context) { lat, lon in
            XCTAssertEqual(lat, 35.6762)
            XCTAssertEqual(lon, 139.6503)
            return GeocodedLocation(countryCode: "JP", countryName: "Japan", city: "Tokyo")
        }

        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<PhotoEntry>()).first)
        XCTAssertEqual(persisted.countryCode, "JP")
        XCTAssertEqual(persisted.flagEmoji, "🇯🇵")
    }

    func testFailedLookupPreservesMetadataAndCanBeRetried() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(day: .now, latitude: 48.8566, longitude: 2.3522,
                               countryName: "France", city: "Paris")
        context.insert(entry)
        try context.save()

        await PhotoStore().backfillLocationDetails(for: [entry], in: context) { _, _ in
            GeocodedLocation(countryCode: nil, countryName: nil, city: nil)
        }
        XCTAssertNil(entry.countryCode)
        XCTAssertEqual(entry.countryName, "France")
        XCTAssertEqual(entry.city, "Paris")

        await PhotoStore().backfillLocationDetails(for: [entry], in: context) { _, _ in
            GeocodedLocation(countryCode: "FR", countryName: nil, city: nil)
        }
        XCTAssertEqual(entry.flagEmoji, "🇫🇷")
        XCTAssertEqual(entry.countryName, "France")
        XCTAssertEqual(entry.city, "Paris")
    }

    func testBackfillRejectsResultForAnEditedCoordinate() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(day: .now, latitude: 35.6762, longitude: 139.6503)
        context.insert(entry)
        try context.save()

        await PhotoStore().backfillLocationDetails(for: [entry], in: context) { _, _ in
            entry.latitude = 48.8566
            entry.longitude = 2.3522
            return GeocodedLocation(countryCode: "JP", countryName: "Japan", city: "Tokyo")
        }
        XCTAssertNil(entry.countryCode)
        XCTAssertNil(entry.city)
    }

    func testBackfillSkipsPhotosWithoutCoordinates() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(day: .now)
        context.insert(entry)
        await PhotoStore().backfillLocationDetails(for: [entry], in: context) { _, _ in
            XCTFail("Photos without coordinates should not be geocoded")
            return GeocodedLocation(countryCode: nil, countryName: nil, city: nil)
        }
        XCTAssertNil(entry.flagEmoji)
    }

    func testInvalidCoordinatesDoNotResolve() async {
        let result = await LocationGeocoder.reverseGeocode(
            latitude: 200, longitude: 300, preferredLocale: Locale(identifier: "en")
        )
        XCTAssertNil(result.countryCode)
        XCTAssertNil(result.city)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }
}
