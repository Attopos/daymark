import Foundation
import SwiftData

@Model
final class PhotoEntry {
    var id: String = UUID().uuidString
    var day: Date
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var captureDate: Date?
    var imageFilename: String?
    var latitude: Double?
    var longitude: Double?
    var timezone: String?
    var countryCode: String?
    var countryName: String?
    var city: String?
    var caption: String?

    init(
        id: String = UUID().uuidString,
        day: Date,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        captureDate: Date? = nil,
        imageFilename: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        timezone: String? = nil,
        countryCode: String? = nil,
        countryName: String? = nil,
        city: String? = nil,
        caption: String? = nil
    ) {
        self.id = id
        self.day = day
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.captureDate = captureDate
        self.imageFilename = imageFilename
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.countryCode = countryCode
        self.countryName = countryName
        self.city = city
        self.caption = caption
    }

    var flagEmoji: String? {
        guard let countryCode, countryCode.count == 2 else { return nil }
        let scalars = countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value)
        }
        guard scalars.count == 2 else { return nil }
        return String(scalars.map { Character($0) })
    }
}
