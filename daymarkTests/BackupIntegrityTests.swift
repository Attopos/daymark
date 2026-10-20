import XCTest
import SwiftData
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Daymark_Journal

@MainActor
final class BackupIntegrityTests: XCTestCase {
    func testUnidentifiedNonGregorianDayKeyIsRejectedRatherThanMisdated() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 7, day: 10)))
        var record = DaymarkBackupEntry(
            id: UUID().uuidString, day: day, captureDate: nil, imageFilename: nil,
            latitude: nil, longitude: nil, timezone: calendar.timeZone.identifier,
            countryCode: nil, countryName: nil, city: nil, caption: nil
        )
        record.dayKey = "0042-06-16"
        XCTAssertThrowsError(try BackupCalendar.restoredDay(record, calendar: calendar)) { error in
            guard case BackupError.invalidEntriesJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func headerOnlyPNG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { renderer in
            UIColor.green.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let completePNG = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(completePNG.count, 33)
        return Data(completePNG.prefix(33))
    }

    func testExportRejectsHeaderOnlyLegacyPhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photoStore = PhotoStore(
            originalsDirectoryURL: root.appendingPathComponent("originals"),
            thumbnailsDirectoryURL: root.appendingPathComponent("thumbnails"),
            viewPhotosDirectoryURL: root.appendingPathComponent("views"),
            conflictPhotosDirectoryURL: root.appendingPathComponent("conflicts"),
            legacyPhotosDirectoryURL: root.appendingPathComponent("legacy")
        )
        let schema = Schema([PhotoEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        // Signature + IHDR is recognizable as a PNG, but contains no pixel
        // data. Merely reading its type and frame count cannot verify a photo.
        let damagedPNG = try headerOnlyPNG()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(damagedPNG as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let imageType = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertEqual(imageType as String, UTType.png.identifier)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        XCTAssertNil(CGImageSourceCreateThumbnailAtIndex(source, 0, options))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 7, day: 10)))
        let entry = PhotoEntry(day: day, imageData: damagedPNG, caption: "An unreadable historical original")
        context.insert(entry)
        try context.save()
        XCTAssertNil(entry.originalContentHash)
        do {
            let export = try await photoStore.makeBackupExportItem(from: [entry], in: context, allowCloudDownload: false)
            defer { export.cleanUp() }
            XCTFail("An original whose header is recognizable but whose pixels cannot decode must not produce a complete backup")
        } catch BackupError.damagedPhoto {
            // Rejection must occur before a supposedly restorable backup is shared.
        } catch {
            XCTFail("Expected damagedPhoto, received \(error)")
        }
        XCTAssertEqual(entry.imageData, damagedPNG)
        XCTAssertNil(entry.localOriginalFilename)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoEntry>()).count, 1)
    }

    func testParserRejectsHeaderOnlyImagesInLegacyJSONAndZIP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photoStore = PhotoStore(
            originalsDirectoryURL: root.appendingPathComponent("originals"),
            thumbnailsDirectoryURL: root.appendingPathComponent("thumbnails"),
            viewPhotosDirectoryURL: root.appendingPathComponent("views"),
            conflictPhotosDirectoryURL: root.appendingPathComponent("conflicts"),
            legacyPhotosDirectoryURL: root.appendingPathComponent("legacy")
        )
        let damagedImage = try headerOnlyPNG()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 7, day: 10)))
        var record = DaymarkBackupEntry(
            id: UUID().uuidString, day: day, captureDate: nil, imageFilename: nil,
            latitude: nil, longitude: nil, timezone: calendar.timeZone.identifier,
            countryCode: nil, countryName: nil, city: nil, caption: "Pixels are missing"
        )
        record.legacyImageData = damagedImage
        let legacyURL = root.appendingPathComponent("header-only-v1.json")
        let legacyPayload = DaymarkBackupPayload(version: 1, exportedAt: day, entries: [record])
        try BackupArchiveReader.encode(legacyPayload).write(to: legacyURL)
        var fixtures = [legacyURL]

        record.legacyImageData = nil
        record.imageFilename = "header-only.png"
        for version in [2, 3] {
            // ZIP CRC, SHA256 and byte counts are all correct for these
            // broken bytes. Integrity checks alone must not certify a photo.
            if version == 3 {
                record.dayKey = "2025-07-10"
                record.imageByteCount = Int64(damagedImage.count)
                record.imageSHA256 = BackupArchiveReader.hash(damagedImage)
            }
            let payload = DaymarkBackupPayload(version: version, exportedAt: day, entries: [record])
            let url = root.appendingPathComponent("header-only-v\(version).zip")
            let archive = ZipArchive.create(entries: [
                .init(path: "entries.json", data: try BackupArchiveReader.encode(payload)),
                .init(path: "images/header-only.png", data: damagedImage)
            ])
            try archive.write(to: url)
            fixtures.append(url)
        }
        for url in fixtures {
            do {
                let contents = try photoStore.parseBackup(from: url)
                defer { contents.cleanUp() }
                XCTFail("\(url.lastPathComponent) must not be previewed as a verified, restorable backup")
            } catch BackupError.damagedPhoto {
                // A parser that rejects the archive needs no library import.
            } catch {
                XCTFail("Expected damagedPhoto for \(url.lastPathComponent), received \(error)")
            }
        }
        for folder in ["originals", "thumbnails", "views", "conflicts", "legacy"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path))
        }
    }

    func testBackupDayKeysAndRestorationUseGregorianDatesAcrossCalendarPreferences() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = shanghai
        let sourceDay = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2025, month: 7, day: 10)))
        var gregorianLA = Calendar(identifier: .gregorian)
        gregorianLA.timeZone = losAngeles
        let expectedLADay = try XCTUnwrap(gregorianLA.date(from: DateComponents(year: 2025, month: 7, day: 10)))
        let expectedKey = "2025-07-10"
        let identifiers: [Calendar.Identifier] = [.gregorian, .buddhist, .chinese]

        for identifier in identifiers {
            var preference = Calendar(identifier: identifier)
            preference.timeZone = shanghai
            XCTAssertEqual(BackupCalendar.dayKey(for: sourceDay, calendar: preference), expectedKey,
                           "Backup day keys must not change with the user's \(identifier) calendar preference")

            for hasExplicitDayKey in [true, false] {
                // Cover both version 3's explicit key and old backups that
                // derive the day from their Date and saved timezone.
                var record = DaymarkBackupEntry(
                    id: UUID().uuidString, day: sourceDay, captureDate: nil, imageFilename: nil,
                    latitude: nil, longitude: nil, timezone: shanghai.identifier,
                    countryCode: nil, countryName: nil, city: nil, caption: nil
                )
                record.dayKey = hasExplicitDayKey ? expectedKey : nil
                XCTAssertEqual(try BackupCalendar.restoredDay(record, calendar: preference), sourceDay,
                               "Restoring with \(identifier), explicit key: \(hasExplicitDayKey), must preserve the Gregorian day")

                var destination = Calendar(identifier: identifier)
                destination.timeZone = losAngeles
                let restoredLA = try BackupCalendar.restoredDay(record, calendar: destination)
                XCTAssertEqual(restoredLA, expectedLADay,
                               "Moving to Los Angeles must retain July 10 under \(identifier), explicit key: \(hasExplicitDayKey)")
                XCTAssertEqual(BackupCalendar.dayKey(for: restoredLA, calendar: destination), expectedKey)
            }
        }
    }
}
