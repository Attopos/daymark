import Foundation
import CoreLocation

/// Country-only fallback when Apple's regional geocoding service has no result.
/// Natural Earth boundaries are approximate; never guess the nearest country
/// for ocean coordinates or areas without an assigned ISO code.
enum OfflineCountryLookup {
    private struct BoundaryFile: Decodable {
        let polygons: [Polygon]
    }

    private struct Polygon: Decodable {
        let code: String
        let bounds: [Double]
        let rings: [[[Double]]]

        func contains(latitude: Double, longitude: Double) -> Bool {
            guard bounds.count == 4, longitude >= bounds[0], latitude >= bounds[1],
                  longitude <= bounds[2], latitude <= bounds[3],
                  let exterior = rings.first,
                  contains(latitude: latitude, longitude: longitude, ring: exterior) else { return false }
            return !rings.dropFirst().contains {
                contains(latitude: latitude, longitude: longitude, ring: $0)
            }
        }

        private func contains(latitude y: Double, longitude x: Double, ring: [[Double]]) -> Bool {
            guard ring.count >= 4 else { return false }
            var inside = false
            var previous = ring[ring.count - 1]
            for point in ring {
                guard point.count == 2, previous.count == 2 else { return false }
                if (point[1] > y) != (previous[1] > y),
                   x < (previous[0] - point[0]) * (y - point[1]) / (previous[1] - point[1]) + point[0] {
                    inside.toggle()
                }
                previous = point
            }
            return inside
        }
    }

    private static let polygons: [Polygon] = {
        guard let url = Bundle.main.url(forResource: "CountryBoundaries", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(BoundaryFile.self, from: data) else { return [] }
        return file.polygons
    }()

    static func countryCode(latitude: Double, longitude: Double) -> String? {
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            return nil
        }
        return polygons.first { $0.contains(latitude: latitude, longitude: longitude) }?.code
    }
}
