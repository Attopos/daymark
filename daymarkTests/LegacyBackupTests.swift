import XCTest
import SwiftData
import UIKit
@testable import Daymark_Journal

/// v1/v2 backups came from libraries that could contain sync duplicates and
/// records whose photo never arrived. They must restore instead of being
/// rejected as a whole, while v3 archives stay strictly validated.
@MainActor
final class LegacyBackupTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func store(_ root: URL) -> PhotoStore {
        PhotoStore(originalsDirectoryURL: root.appendingPathComponent("originals"),
                   thumbnailsDirectoryURL: root.appendingPathComponent("thumbnails"),
                   viewPhotosDirectoryURL: root.appendingPathComponent("views"),
                   conflictPhotosDirectoryURL: root.appendingPathComponent("conflicts"),
                   legacyPhotosDirectoryURL: root.appendingPathComponent("legacy"))
    }

    private func container() throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    private func png(_ color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset,
                              to: Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 10))!)!
    }

    private func record(id: String?, day: Date, filename: String?, city: String? = nil, caption: String? = nil) -> DaymarkBackupEntry {
        DaymarkBackupEntry(id: id, day: day, captureDate: nil, imageFilename: filename,
                           latitude: nil, longitude: nil, timezone: TimeZone.current.identifier,
                           countryCode: nil, countryName: nil, city: city, caption: caption)
    }

    func testV2ArchiveWithDuplicateDaysIDsAndMissingPhotoRestores() async throws {
        let root = try directory(), photoStore = store(root)
        let red = try png(.red), blue = try png(.blue), green = try png(.green)
        // The v2 writer named photos "<id>.jpg", so a duplicated ID wrote the
        // same path once per record, in record order.
        let entries = [
            record(id: "dup", day: day(0), filename: "dup.jpg", city: "Paris"),
            record(id: "dup", day: day(0), filename: "dup.jpg", caption: "Later"),
            record(id: "dup", day: day(1), filename: "dup.jpg", caption: "Next day"),
            record(id: "no-photo", day: day(2), filename: nil, caption: "Photo never arrived")
        ]
        let payload = DaymarkBackupPayload(version: 2, exportedAt: day(3), entries: entries)
        let url = root.appendingPathComponent("legacy-v2.zip")
        try ZipArchive.create(entries: [
            .init(path: "entries.json", data: try BackupArchiveReader.encode(payload)),
            .init(path: "images/dup.jpg", data: red),
            .init(path: "images/dup.jpg", data: blue),
            .init(path: "images/dup.jpg", data: green)
        ]).write(to: url)

        let backup = try photoStore.parseBackup(from: url)
        defer { backup.cleanUp() }
        XCTAssertEqual(backup.legacyReport, LegacyRestoreReport(entriesWithoutPhoto: 1, duplicateDaysMerged: 1))
        XCTAssertEqual(backup.payload.entries.count, 2)
        let first = try XCTUnwrap(backup.payload.entries.first { $0.caption == "Later" })
        let second = try XCTUnwrap(backup.payload.entries.first { $0.caption == "Next day" })
        XCTAssertEqual(first.city, "Paris", "Missing details are filled from the other same-day record")
        XCTAssertEqual(backup.imageData(named: try XCTUnwrap(first.imageFilename)), blue)
        XCTAssertEqual(backup.imageData(named: try XCTUnwrap(second.imageFilename)), green)

        let context = ModelContext(try container())
        let result = try await photoStore.importBackup(from: backup, mode: .merge, into: context)
        XCTAssertEqual(result.imported, 2)
        let restored = try context.fetch(FetchDescriptor<PhotoEntry>(sortBy: [SortDescriptor(\.day)]))
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].caption, "Later")
        XCTAssertEqual(restored[0].city, "Paris")
        XCTAssertEqual(photoStore.originalData(for: restored[0]), blue)
        XCTAssertEqual(restored[1].caption, "Next day")
        XCTAssertEqual(photoStore.originalData(for: restored[1]), green)
        XCTAssertEqual(Set(restored.map(\.id)).count, 2, "A repeated backup ID must not be reused")
    }

    func testV1JSONWithDuplicateDaysAndMissingPhotoRestores() async throws {
        let root = try directory(), photoStore = store(root)
        let red = try png(.red), blue = try png(.blue)
        var earlier = record(id: "a", day: day(0), filename: "a.jpg", caption: "Richer record")
        earlier.legacyImageData = red
        var later = record(id: "b", day: day(0), filename: "b.jpg")
        later.legacyImageData = blue
        let missing = record(id: "c", day: day(1), filename: nil)
        let payload = DaymarkBackupPayload(version: 1, exportedAt: day(2), entries: [earlier, later, missing])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent("legacy.json")
        try encoder.encode(payload).write(to: url)

        let backup = try photoStore.parseBackup(from: url)
        XCTAssertEqual(backup.legacyReport, LegacyRestoreReport(entriesWithoutPhoto: 1, duplicateDaysMerged: 1))
        let context = ModelContext(try container())
        let result = try await photoStore.importBackup(from: backup, mode: .merge, into: context)
        XCTAssertEqual(result.imported, 1)
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoEntry>()).first)
        XCTAssertEqual(restored.caption, "Richer record", "The record with more details wins")
        XCTAssertEqual(photoStore.originalData(for: restored), red)
    }

    func testV3ArchivesStillRejectDuplicateDays() {
        var first = record(id: "a", day: day(0), filename: nil)
        first.dayKey = BackupCalendar.dayKey(for: day(0))
        var second = record(id: "b", day: day(0), filename: nil)
        second.dayKey = first.dayKey
        let payload = DaymarkBackupPayload(version: 3, exportedAt: day(1), entries: [first, second])
        XCTAssertThrowsError(try BackupArchiveReader.validateMetadata(payload)) { error in
            guard case BackupError.duplicateDay = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLaunchCleanupRemovesAbandonedWorkingDirectories() throws {
        let abandoned = try BackupArchiveReader.makeWorkingDirectory(prefix: "import")
        try Data("partial".utf8).write(to: abandoned.appendingPathComponent("photo.jpg"))
        BackupArchiveReader.removeStaleWorkingDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        // New operations can still create their directories afterwards.
        let fresh = try BackupArchiveReader.makeWorkingDirectory(prefix: "export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        try? FileManager.default.removeItem(at: fresh)
    }
}
