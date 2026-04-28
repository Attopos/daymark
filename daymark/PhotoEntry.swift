import Foundation
import SwiftData

@Model
final class PhotoEntry {
    @Attribute(.unique) var day: Date
    var imageFilename: String
    var latitude: Double?
    var longitude: Double?

    init(day: Date, imageFilename: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.day = day
        self.imageFilename = imageFilename
        self.latitude = latitude
        self.longitude = longitude
    }
}
