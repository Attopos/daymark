import Foundation
import SwiftData

@Model
final class PhotoEntry {
    @Attribute(.unique) var day: Date
    var imageFilename: String

    init(day: Date, imageFilename: String) {
        self.day = day
        self.imageFilename = imageFilename
    }
}
