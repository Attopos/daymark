import XCTest
import SwiftData
import UIKit
import CryptoKit
import ZIPFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import Daymark_Journal

@MainActor
final class BackupTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    private func diskContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

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

    private func png(_ color: UIColor = .green) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func day(_ offset: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: offset,
                              to: Calendar.current.date(from: DateComponents(year: 2025, month: 7, day: 10))!)!
    }

    private func metadata(_ day: Date, id: String = UUID().uuidString, filename: String? = nil) -> DaymarkBackupEntry {
        DaymarkBackupEntry(id: id, day: day, captureDate: day, imageFilename: filename,
                          latitude: 35.6762, longitude: 139.6503, timezone: TimeZone.current.identifier,
                          countryCode: "JP", countryName: "Japan", city: "Tokyo", caption: "A quiet day")
    }

    private func snapshot(_ entry: PhotoEntry) -> DaymarkBackupEntry {
        var record = DaymarkBackupEntry(
            id: entry.id, day: entry.day, captureDate: entry.captureDate, imageFilename: nil,
            latitude: entry.latitude, longitude: entry.longitude, timezone: entry.timezone,
            countryCode: entry.countryCode, countryName: entry.countryName, city: entry.city, caption: entry.caption
        )
        record.dayKey = BackupCalendar.dayKey(for: entry.day)
        return record
    }

    private func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertMetadata(
        _ entry: PhotoEntry, matches expected: DaymarkBackupEntry,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(entry.id, expected.id, file: file, line: line)
        XCTAssertEqual(entry.day, expected.day, file: file, line: line)
        XCTAssertEqual(entry.captureDate, expected.captureDate, file: file, line: line)
        XCTAssertEqual(entry.latitude, expected.latitude, file: file, line: line)
        XCTAssertEqual(entry.longitude, expected.longitude, file: file, line: line)
        XCTAssertEqual(entry.timezone, expected.timezone, file: file, line: line)
        XCTAssertEqual(entry.countryCode, expected.countryCode, file: file, line: line)
        XCTAssertEqual(entry.countryName, expected.countryName, file: file, line: line)
        XCTAssertEqual(entry.city, expected.city, file: file, line: line)
        XCTAssertEqual(entry.caption, expected.caption, file: file, line: line)
    }

    private func assertArchiveRecord(
        _ actual: DaymarkBackupEntry, matches expected: DaymarkBackupEntry,
        original: Data, contents: BackupContents,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let filename = try XCTUnwrap(actual.imageFilename, file: file, line: line)
        var expectedRecord = expected
        expectedRecord.imageFilename = filename
        expectedRecord.imageByteCount = Int64(original.count)
        expectedRecord.imageSHA256 = checksum(original)
        XCTAssertEqual(actual, expectedRecord, file: file, line: line)
        let archivedOriginal = try XCTUnwrap(contents.imageData(named: filename), file: file, line: line)
        XCTAssertEqual(archivedOriginal, original, file: file, line: line)
        XCTAssertEqual(checksum(archivedOriginal), checksum(original), file: file, line: line)
    }

    private func assertReadableAssets(
        for entry: PhotoEntry, original: Data, in photoStore: PhotoStore,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Check the persisted representations too: the UI's image methods may
        // otherwise succeed by falling back to an original or an image cache.
        XCTAssertNil(entry.imageData, file: file, line: line)
        XCTAssertNil(entry.imageFilename, file: file, line: line)
        XCTAssertNil(entry.thumbnailData, file: file, line: line)
        XCTAssertNotNil(entry.localOriginalFilename, file: file, line: line)
        XCTAssertNotNil(entry.localThumbnailFilename, file: file, line: line)
        XCTAssertNotNil(entry.localViewPhotoFilename, file: file, line: line)
        let restoredOriginal = try XCTUnwrap(photoStore.originalData(for: entry), file: file, line: line)
        XCTAssertEqual(restoredOriginal, original, file: file, line: line)
        XCTAssertEqual(entry.originalByteCount, Int64(original.count), file: file, line: line)
        XCTAssertEqual(entry.originalContentHash, checksum(original), file: file, line: line)
        let thumbnail = try XCTUnwrap(photoStore.thumbnailData(for: entry), file: file, line: line)
        let view = try XCTUnwrap(photoStore.viewPhotoData(for: entry), file: file, line: line)
        XCTAssertEqual(entry.thumbnailByteCount, Int64(thumbnail.count), file: file, line: line)
        XCTAssertEqual(entry.thumbnailContentHash, checksum(thumbnail), file: file, line: line)
        XCTAssertEqual(entry.viewPhotoByteCount, Int64(view.count), file: file, line: line)
        XCTAssertEqual(entry.viewPhotoContentHash, checksum(view), file: file, line: line)
        XCTAssertNotNil(UIImage(data: restoredOriginal), file: file, line: line)
        XCTAssertNotNil(UIImage(data: thumbnail), file: file, line: line)
        XCTAssertNotNil(UIImage(data: view), file: file, line: line)
        XCTAssertNotNil(photoStore.image(for: entry), file: file, line: line)
        XCTAssertNotNil(photoStore.thumbnail(for: entry), file: file, line: line)
        XCTAssertNotNil(photoStore.viewImage(for: entry), file: file, line: line)
    }

    private func metadataImage(ofType type: UTType) throws -> Data {
        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if type == .heic && !supportedTypes.contains(type.identifier) {
            throw XCTSkip("This test runtime does not expose a HEIC encoder; JPEG and PNG run independently")
        }
        XCTAssertTrue(supportedTypes.contains(type.identifier), "Missing \(type.identifier) fixture encoder")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            UIColor.orange.setFill()
            renderer.fill(CGRect(x: 4, y: 8, width: 20, height: 16))
        }
        let pixels = try XCTUnwrap(image.cgImage)
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, type.identifier as CFString, 1, nil)
        if type == .heic && destination == nil {
            throw XCTSkip("This test runtime cannot create a HEIC image destination; no substitute format is used")
        }
        let encoder = try XCTUnwrap(destination)
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2025:07:10 14:15:16",
            kCGImagePropertyExifDateTimeDigitized: "2025:07:10 14:15:16",
            kCGImagePropertyExifSubsecTimeOriginal: "125"
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Daymark Test Camera",
            kCGImagePropertyTIFFModel: "Synthetic 64x48",
            kCGImagePropertyTIFFOrientation: 6
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 31.25,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 121.5,
            kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 12.75,
            kCGImagePropertyGPSAltitudeRef: 0,
            kCGImagePropertyGPSDateStamp: "2025:07:10",
            kCGImagePropertyGPSTimeStamp: "06:15:16"
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyGPSDictionary: gps
        ]
        CGImageDestinationAddImage(encoder, pixels, properties as CFDictionary)
        let finalized = CGImageDestinationFinalize(encoder)
        if type == .heic && !finalized {
            throw XCTSkip("HEIC encoding is unavailable in this test runtime; no JPEG is disguised as HEIC")
        }
        XCTAssertTrue(finalized, "Could not encode the \(type.identifier) fixture")
        return encoded as Data
    }

    @discardableResult
    private func assertEmbeddedImageMetadata(
        in data: Data, type: UTType,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSDictionary {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetCount(source), 1, file: file, line: line)
        let actualType = try XCTUnwrap(CGImageSourceGetType(source), file: file, line: line)
        XCTAssertEqual(actualType as String, type.identifier, file: file, line: line)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], file: file, line: line)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 64, file: file, line: line)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 48, file: file, line: line)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6, file: file, line: line)
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any], file: file, line: line)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2025:07:10 14:15:16", file: file, line: line)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeDigitized] as? String, "2025:07:10 14:15:16", file: file, line: line)
        XCTAssertEqual(exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, "125", file: file, line: line)
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], file: file, line: line)
        let latitude = try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? NSNumber, file: file, line: line)
        let longitude = try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? NSNumber, file: file, line: line)
        XCTAssertEqual(latitude.doubleValue, 31.25, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(longitude.doubleValue, 121.5, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "N", file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "E", file: file, line: line)
        return properties as NSDictionary
    }

    private func assertMetadataImageRoundTrip(
        ofType type: UTType, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let original = try metadataImage(ofType: type)
        let originalProperties = try assertEmbeddedImageMetadata(in: original, type: type, file: file, line: line)
        let source = store(try directory()), target = store(try directory())
        XCTAssertTrue(source.hasEmbeddedLocation(in: original), file: file, line: line)
        let sourceContainer = try container(), sourceContext = ModelContext(sourceContainer)
        let targetContainer = try container(), targetContext = ModelContext(targetContainer)
        let entry = PhotoEntry(
            day: day(), imageData: original, captureDate: day().addingTimeInterval(51_316.125),
            latitude: 31.230416, longitude: 121.473701, timezone: "Asia/Shanghai",
            countryCode: "CN", countryName: "中国", city: "上海", caption: "\(type.identifier) 的原始照片 📷"
        )
        sourceContext.insert(entry)
        try sourceContext.save()
        let expected = snapshot(entry)
        let export = try await source.makeBackupExportItem(from: [entry], in: sourceContext, allowCloudDownload: false)
        defer { export.cleanUp() }
        XCTAssertEqual(export.entryCount, 1, file: file, line: line)
        let backup = try target.parseBackup(from: export.url)
        defer { backup.cleanUp() }
        XCTAssertEqual(backup.payload.entries.count, 1, file: file, line: line)
        let record = try XCTUnwrap(backup.payload.entries.first, file: file, line: line)
        try assertArchiveRecord(record, matches: expected, original: original, contents: backup, file: file, line: line)
        let filename = try XCTUnwrap(record.imageFilename, file: file, line: line)
        XCTAssertEqual(URL(fileURLWithPath: filename).pathExtension, type.preferredFilenameExtension, file: file, line: line)
        let archivedOriginal = try XCTUnwrap(backup.imageData(named: filename), file: file, line: line)
        XCTAssertEqual(try assertEmbeddedImageMetadata(in: archivedOriginal, type: type, file: file, line: line),
                       originalProperties, file: file, line: line)

        let result = try await target.importBackup(from: backup, mode: .merge, into: targetContext)
        XCTAssertEqual(result.imported, 1, file: file, line: line)
        XCTAssertEqual(result.skipped, 0, file: file, line: line)
        let restored = try targetContext.fetch(FetchDescriptor<PhotoEntry>())
        XCTAssertEqual(restored.count, 1, file: file, line: line)
        let restoredEntry = try XCTUnwrap(restored.first, file: file, line: line)
        assertMetadata(restoredEntry, matches: expected, file: file, line: line)
        try assertReadableAssets(for: restoredEntry, original: original, in: target, file: file, line: line)
        let restoredOriginal = try XCTUnwrap(target.originalData(for: restoredEntry), file: file, line: line)
        XCTAssertEqual(try assertEmbeddedImageMetadata(in: restoredOriginal, type: type, file: file, line: line),
                       originalProperties, file: file, line: line)
        XCTAssertTrue(target.hasEmbeddedLocation(in: restoredOriginal), file: file, line: line)
        // Orientation 6 rotates the 64x48 pixels clockwise. The regenerated
        // display images must be usable without EXIF orientation handling.
        let thumbnail = try XCTUnwrap(target.thumbnail(for: restoredEntry)?.cgImage, file: file, line: line)
        let view = try XCTUnwrap(target.viewImage(for: restoredEntry)?.cgImage, file: file, line: line)
        XCTAssertEqual(thumbnail.width, 48, file: file, line: line)
        XCTAssertEqual(thumbnail.height, 64, file: file, line: line)
        XCTAssertEqual(view.width, 48, file: file, line: line)
        XCTAssertEqual(view.height, 64, file: file, line: line)
    }

    func testJPEGOriginalRoundTripPreservesEXIFGPSAndOrientation() async throws {
        try await assertMetadataImageRoundTrip(ofType: .jpeg)
    }

    func testPNGOriginalRoundTripPreservesEXIFGPSAndOrientation() async throws {
        try await assertMetadataImageRoundTrip(ofType: .png)
    }

    func testHEICOriginalRoundTripPreservesEXIFGPSAndOrientation() async throws {
        try await assertMetadataImageRoundTrip(ofType: .heic)
    }

    func testUpgradeExportsEmbeddedLegacyAndModernOriginalsWithoutMigration() async throws {
        let root = try directory(), photoStore = store(root)
        let modelContainer = try container(), context = ModelContext(modelContainer)
        let embeddedData = try png(.green), legacyData = try png(.blue), modernData = try png(.orange)
        let embedded = PhotoEntry(day: day(), imageData: embeddedData, captureDate: day(), countryCode: "JP", caption: "Old embedded photo")
        let legacy = PhotoEntry(day: day(1), imageFilename: "legacy-original.png", latitude: 48.8566, longitude: 2.3522)
        let modern = PhotoEntry(day: day(2), countryCode: "US")
        for entry in [embedded, legacy, modern] { context.insert(entry) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("legacy"), withIntermediateDirectories: true)
        try legacyData.write(to: root.appendingPathComponent("legacy/legacy-original.png"))
        try photoStore.storeDownloadedOriginal(modernData, for: modern)
        try context.save()
        let export = try await photoStore.makeBackupExportItem(from: [embedded, legacy, modern], in: context, allowCloudDownload: false)
        defer { export.cleanUp() }
        let backup = try photoStore.parseBackup(from: export.url)
        defer { backup.cleanUp() }
        XCTAssertEqual(backup.payload.version, 3)
        XCTAssertEqual(export.entryCount, 3)
        for (entry, original) in zip(backup.payload.entries, [embeddedData, legacyData, modernData]) {
            XCTAssertTrue(entry.imageFilename?.hasSuffix(".png") == true)
            XCTAssertEqual(backup.imageData(named: try XCTUnwrap(entry.imageFilename)), original)
            XCTAssertEqual(entry.imageSHA256, BackupArchiveReader.hash(original))
        }
        XCTAssertEqual(embedded.imageData, embeddedData)
        XCTAssertEqual(legacy.imageFilename, "legacy-original.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy/legacy-original.png").path))
    }

    func testExportDownloadsOnlyMissingOriginalAndVerifiesIt() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let data = try png()
        let local = PhotoEntry(day: day(), imageData: data)
        let remote = PhotoEntry(day: day(1), originalContentHash: BackupArchiveReader.hash(data))
        context.insert(local); context.insert(remote); try context.save()
        let cloud = BackupRemoteStore(id: remote.id, data: data)
        let export = try await photoStore.makeBackupExportItem(from: [local, remote], in: context, allowCloudDownload: true, remoteStore: cloud)
        defer { export.cleanUp() }
        XCTAssertEqual(cloud.downloads, [remote.id])
        XCTAssertEqual(cloud.uploads, 0)
        XCTAssertEqual(photoStore.originalData(for: remote), data)
        XCTAssertEqual(remote.originalSyncState, .synced)
    }

    func testMissingOriginalFailsInsteadOfCreatingPartialBackup() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let entry = PhotoEntry(day: day(), thumbnailData: try png())
        context.insert(entry); try context.save()
        do {
            _ = try await photoStore.makeBackupExportItem(from: [entry], in: context, allowCloudDownload: false)
            XCTFail("A thumbnail must never substitute for the missing original")
        } catch BackupError.missingOriginal { }
        XCTAssertNotNil(entry.thumbnailData)
        XCTAssertNil(entry.localOriginalFilename)
    }

    func testCorruptCloudOriginalIsNotSaved() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let data = try png()
        let entry = PhotoEntry(day: day())
        context.insert(entry); try context.save()
        let cloud = BackupRemoteStore(id: entry.id, data: data, advertisedHash: String(repeating: "0", count: 64))
        do {
            _ = try await photoStore.makeBackupExportItem(from: [entry], in: context, allowCloudDownload: true, remoteStore: cloud)
            XCTFail("Corrupt download should fail")
        } catch BackupError.damagedPhoto { }
        XCTAssertNil(photoStore.originalData(for: entry))
    }

    func testExportDetectsPhotoReplacementWhileWriting() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let original = try png(.blue), replacement = try png(.red)
        let entry = PhotoEntry(day: day(), imageData: original)
        context.insert(entry); try context.save()
        do {
            _ = try await photoStore.makeBackupExportItem(from: [entry], in: context, allowCloudDownload: false) { done, _, _ in
                if done == 1 { entry.imageData = replacement }
            }
            XCTFail("A changing library must not be marked as a complete snapshot")
        } catch BackupError.libraryChanged { }
        XCTAssertEqual(entry.imageData, replacement)
    }

    func testRoundTripIntoEmptyLibraryKeepsOriginalAndMetadata() async throws {
        let source = store(try directory()), target = store(try directory())
        let sourceContainer = try container(), sourceContext = ModelContext(sourceContainer)
        let targetContainer = try container(), targetContext = ModelContext(targetContainer)
        let data = try png()
        let entry = PhotoEntry(day: day(), imageData: data, captureDate: day().addingTimeInterval(123.125),
                               latitude: 35.6762, longitude: 139.6503, timezone: TimeZone.current.identifier,
                               countryCode: "JP", countryName: "Japan", city: "Tokyo", caption: "雨后的街角 🌿")
        sourceContext.insert(entry); try sourceContext.save()
        let export = try await source.makeBackupExportItem(from: [entry], in: sourceContext, allowCloudDownload: false)
        defer { export.cleanUp() }
        let backup = try target.parseBackup(from: export.url)
        defer { backup.cleanUp() }
        let summary = try await target.importBackup(from: backup, mode: .merge, into: targetContext)
        let restored = try XCTUnwrap(targetContext.fetch(FetchDescriptor<PhotoEntry>()).first)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(restored.id, entry.id)
        XCTAssertEqual(restored.day, entry.day)
        XCTAssertEqual(restored.caption, entry.caption)
        XCTAssertEqual(restored.captureDate, entry.captureDate)
        XCTAssertEqual(restored.latitude, entry.latitude)
        XCTAssertEqual(restored.countryCode, "JP")
        XCTAssertEqual(target.originalData(for: restored), data)
        XCTAssertNotNil(target.thumbnail(for: restored))
        XCTAssertNotNil(target.viewImage(for: restored))
    }

    func testFullLibraryRoundTripPreservesEveryUserFieldAndOriginalBytes() async throws {
        let sourceRoot = try directory(), targetRoot = try directory()
        let source = store(sourceRoot), target = store(targetRoot)
        let sourceContainer = try container(), sourceContext = ModelContext(sourceContainer)
        let targetContainer = try container(), targetContext = ModelContext(targetContainer)
        let originals = [try png(.green), try png(.purple), try png(.orange)]
        let embedded = PhotoEntry(
            day: day(), imageData: originals[0], captureDate: day().addingTimeInterval(35_123.125),
            latitude: 31.230416, longitude: 121.473701, timezone: "Asia/Shanghai",
            countryCode: "CN", countryName: "中国", city: "上海市",
            caption: "雨后的街角 🌿\n第二行：\"记住今天\"\t👨‍👩‍👧‍👦"
        )
        let modern = PhotoEntry(
            day: day(1), captureDate: day(1).addingTimeInterval(43_210.875),
            latitude: -33.86882, longitude: 151.20929, timezone: "Australia/Sydney",
            countryCode: "AU", countryName: "澳大利亚", city: "悉尼", caption: ""
        )
        // All optional user metadata is deliberately nil in the third entry.
        let legacy = PhotoEntry(day: day(2), imageFilename: "旧相片 original.png")
        let entries = [embedded, modern, legacy]
        for entry in entries { sourceContext.insert(entry) }
        try source.storeDownloadedOriginal(originals[1], for: modern)
        let legacyURL = sourceRoot.appendingPathComponent("legacy/旧相片 original.png")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originals[2].write(to: legacyURL)
        try sourceContext.save()
        let expected = entries.map(snapshot)

        let export = try await source.makeBackupExportItem(from: entries, in: sourceContext, allowCloudDownload: false)
        defer { export.cleanUp() }
        let backup = try target.parseBackup(from: export.url)
        defer { backup.cleanUp() }
        XCTAssertEqual(export.entryCount, entries.count)
        XCTAssertGreaterThan(export.byteCount, 0)
        XCTAssertEqual(backup.payload.version, 3)
        XCTAssertEqual(backup.payload.entries.count, expected.count)
        for (index, metadata) in expected.enumerated() {
            let record = try XCTUnwrap(backup.payload.entries.first { $0.id == metadata.id })
            try assertArchiveRecord(record, matches: metadata, original: originals[index], contents: backup)
        }

        let summary = try await target.importBackup(from: backup, mode: .merge, into: targetContext)
        XCTAssertEqual(summary.imported, entries.count)
        XCTAssertEqual(summary.skipped, 0)
        let restored = try targetContext.fetch(FetchDescriptor<PhotoEntry>())
        XCTAssertEqual(restored.count, entries.count)
        XCTAssertEqual(Set(restored.map(\.id)), Set(entries.map(\.id)))
        for (index, record) in expected.enumerated() {
            let entry = try XCTUnwrap(restored.first { $0.id == record.id })
            assertMetadata(entry, matches: record)
            try assertReadableAssets(for: entry, original: originals[index], in: target)
        }
        XCTAssertEqual(embedded.imageData, originals[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testRestoredDiskLibraryReopensAndMetadataEditsSurviveAnotherRoundTrip() async throws {
        let source = store(try directory())
        let sourceContainer = try container(), sourceContext = ModelContext(sourceContainer)
        let original = try png(.blue)
        let sourceEntry = PhotoEntry(
            day: day(), imageData: original, captureDate: day().addingTimeInterval(12_345.625),
            latitude: 35.6762, longitude: 139.6503, timezone: "Asia/Tokyo",
            countryCode: "JP", countryName: "日本", city: "东京", caption: "最初的记录 📷\n保留拍摄时间"
        )
        sourceContext.insert(sourceEntry)
        try sourceContext.save()
        let expected = snapshot(sourceEntry)
        let export = try await source.makeBackupExportItem(from: [sourceEntry], in: sourceContext, allowCloudDownload: false)
        defer { export.cleanUp() }
        let targetRoot = try directory(), target = store(targetRoot)
        let databaseURL = targetRoot.appendingPathComponent("restored-library.store")
        let backup = try target.parseBackup(from: export.url)
        defer { backup.cleanUp() }
        do {
            let importedContainer = try diskContainer(at: databaseURL)
            let importedContext = ModelContext(importedContainer)
            let summary = try await target.importBackup(from: backup, mode: .merge, into: importedContext)
            XCTAssertEqual(summary.imported, 1)
            XCTAssertEqual(summary.skipped, 0)
            try importedContext.save()
        }

        var editedExpected = DaymarkBackupEntry(
            id: expected.id, day: expected.day, captureDate: expected.captureDate, imageFilename: nil,
            latitude: 22.3193039, longitude: 114.1693611, timezone: "Asia/Hong_Kong",
            countryCode: "HK", countryName: "中国香港", city: "九龙",
            caption: "导入后还可以修改 ✍️\n新的地点与记忆"
        )
        editedExpected.dayKey = expected.dayKey
        do {
            // This is a new container and context, rather than a fetch from
            // the context that performed the import.
            let reopenedContainer = try diskContainer(at: databaseURL)
            let reopenedContext = ModelContext(reopenedContainer)
            let entries = try reopenedContext.fetch(FetchDescriptor<PhotoEntry>())
            XCTAssertEqual(entries.count, 1)
            let restored = try XCTUnwrap(entries.first)
            assertMetadata(restored, matches: expected)
            try assertReadableAssets(for: restored, original: original, in: target)
            restored.caption = editedExpected.caption
            restored.latitude = editedExpected.latitude
            restored.longitude = editedExpected.longitude
            restored.timezone = editedExpected.timezone
            restored.countryCode = editedExpected.countryCode
            restored.countryName = editedExpected.countryName
            restored.city = editedExpected.city
            restored.metadataSyncState = .localOnly
            try reopenedContext.save()
        }

        var editedExport: DaymarkBackupExportItem?
        do {
            // Reopen once more so exporting cannot accidentally use an
            // unsaved metadata edit from a previous context.
            let editedContainer = try diskContainer(at: databaseURL)
            let editedContext = ModelContext(editedContainer)
            let entries = try editedContext.fetch(FetchDescriptor<PhotoEntry>())
            XCTAssertEqual(entries.count, 1)
            let edited = try XCTUnwrap(entries.first)
            assertMetadata(edited, matches: editedExpected)
            try assertReadableAssets(for: edited, original: original, in: target)
            editedExport = try await target.makeBackupExportItem(from: entries, in: editedContext, allowCloudDownload: false)
        }
        let secondExport = try XCTUnwrap(editedExport)
        defer { secondExport.cleanUp() }
        let finalStore = store(try directory()), finalContainer = try container()
        let finalContext = ModelContext(finalContainer)
        let editedBackup = try finalStore.parseBackup(from: secondExport.url)
        defer { editedBackup.cleanUp() }
        XCTAssertEqual(editedBackup.payload.entries.count, 1)
        try assertArchiveRecord(try XCTUnwrap(editedBackup.payload.entries.first), matches: editedExpected,
                                original: original, contents: editedBackup)
        let summary = try await finalStore.importBackup(from: editedBackup, mode: .merge, into: finalContext)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.skipped, 0)
        let finalEntries = try finalContext.fetch(FetchDescriptor<PhotoEntry>())
        XCTAssertEqual(finalEntries.count, 1)
        let finalEntry = try XCTUnwrap(finalEntries.first)
        assertMetadata(finalEntry, matches: editedExpected)
        try assertReadableAssets(for: finalEntry, original: original, in: finalStore)
    }

    func testRestoredPhotoCanBeEditedAndReexportedWithReplacementOriginal() async throws {
        let source = store(try directory()), sourceContainer = try container()
        let sourceContext = ModelContext(sourceContainer)
        let original = try png(.green)
        let sourceEntry = PhotoEntry(day: day(), imageData: original,
                                     captureDate: day().addingTimeInterval(98.125),
                                     latitude: 31.230416, longitude: 121.473701, timezone: "Asia/Shanghai",
                                     countryCode: "CN", countryName: "中国", city: "上海", caption: "编辑照片后仍保留的记忆 🌳")
        sourceContext.insert(sourceEntry)
        try sourceContext.save()
        let expected = snapshot(sourceEntry)
        let firstExport = try await source.makeBackupExportItem(from: [sourceEntry], in: sourceContext, allowCloudDownload: false)
        defer { firstExport.cleanUp() }
        let targetRoot = try directory(), target = store(targetRoot), targetContainer = try container()
        let targetContext = ModelContext(targetContainer)
        let backup = try target.parseBackup(from: firstExport.url)
        defer { backup.cleanUp() }
        let initialImport = try await target.importBackup(from: backup, mode: .merge, into: targetContext)
        XCTAssertEqual(initialImport.imported, 1)
        let restored = try XCTUnwrap(targetContext.fetch(FetchDescriptor<PhotoEntry>()).first)
        try assertReadableAssets(for: restored, original: original, in: target)
        let oldOriginalFilename = try XCTUnwrap(restored.localOriginalFilename)
        let oldThumbnailFilename = try XCTUnwrap(restored.localThumbnailFilename)
        let oldViewFilename = try XCTUnwrap(restored.localViewPhotoFilename)
        let replacementImage = try XCTUnwrap(UIImage(data: try png(.magenta)))
        let replacement = try XCTUnwrap(replacementImage.jpegData(compressionQuality: 0.92))
        // Use the normal photo-editor save path; it is synchronous and never
        // invokes a network geocoder or any remote photo service.
        try target.saveEditedImage(replacementImage, for: restored, in: targetContext)
        XCTAssertNotEqual(replacement, original)
        assertMetadata(restored, matches: expected)
        try assertReadableAssets(for: restored, original: replacement, in: target)
        XCTAssertNotEqual(restored.localOriginalFilename, oldOriginalFilename)
        XCTAssertNotEqual(restored.localThumbnailFilename, oldThumbnailFilename)
        XCTAssertNotEqual(restored.localViewPhotoFilename, oldViewFilename)
        for (folder, filename) in [("originals", oldOriginalFilename), ("thumbnails", oldThumbnailFilename), ("views", oldViewFilename)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent(folder).appendingPathComponent(filename).path))
        }

        let editedEntries = try targetContext.fetch(FetchDescriptor<PhotoEntry>())
        XCTAssertEqual(editedEntries.count, 1)
        let secondExport = try await target.makeBackupExportItem(from: editedEntries, in: targetContext, allowCloudDownload: false)
        defer { secondExport.cleanUp() }
        let finalStore = store(try directory()), finalContainer = try container()
        let finalContext = ModelContext(finalContainer)
        let editedBackup = try finalStore.parseBackup(from: secondExport.url)
        defer { editedBackup.cleanUp() }
        XCTAssertEqual(editedBackup.payload.entries.count, 1)
        try assertArchiveRecord(try XCTUnwrap(editedBackup.payload.entries.first), matches: expected,
                                original: replacement, contents: editedBackup)
        let finalImport = try await finalStore.importBackup(from: editedBackup, mode: .merge, into: finalContext)
        XCTAssertEqual(finalImport.imported, 1)
        XCTAssertEqual(finalImport.skipped, 0)
        let finalEntries = try finalContext.fetch(FetchDescriptor<PhotoEntry>())
        XCTAssertEqual(finalEntries.count, 1)
        let finalEntry = try XCTUnwrap(finalEntries.first)
        assertMetadata(finalEntry, matches: expected)
        try assertReadableAssets(for: finalEntry, original: replacement, in: finalStore)
    }

    func testLegacyJSONWithEmbeddedOriginalStillRestores() async throws {
        let root = try directory(), photoStore = store(root), modelContainer = try container(), context = ModelContext(modelContainer)
        let data = try png()
        var record = metadata(day())
        record.legacyImageData = data
        let payload = DaymarkBackupPayload(version: 1, exportedAt: day(), entries: [record])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent("legacy.json")
        try encoder.encode(payload).write(to: url)
        let backup = try photoStore.parseBackup(from: url)
        let result = try await photoStore.importBackup(from: backup, mode: .merge, into: context)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(photoStore.originalData(for: try XCTUnwrap(context.fetch(FetchDescriptor<PhotoEntry>()).first)), data)
    }

    func testBadSecondPhotoDoesNotReplaceFirstExistingPhoto() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let old = try png(.blue), new = try png(.red)
        let existing = PhotoEntry(day: day(), imageData: old, caption: "Keep this")
        context.insert(existing); try context.save()
        var first = metadata(day()); first.legacyImageData = new
        var broken = metadata(day(1)); broken.legacyImageData = Data("not an image".utf8)
        let backup = BackupContents(payload: DaymarkBackupPayload(version: 1, exportedAt: day(), entries: [first, broken]))
        do {
            try await photoStore.importBackup(from: backup, mode: .overwrite, into: context)
            XCTFail("Invalid image should reject the whole restore")
        } catch { }
        XCTAssertEqual(existing.caption, "Keep this")
        XCTAssertEqual(photoStore.originalData(for: existing), old)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoEntry>()).count, 1)
    }

    func testMergeReportsActualCountsAndOverwritePreservesLocalIdentity() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let old = try png(.blue), new = try png(.red)
        let existing = PhotoEntry(id: "local-id", day: day(), imageData: old)
        context.insert(existing); try context.save()
        var record = metadata(day(), id: "backup-id"); record.legacyImageData = new
        let backup = BackupContents(payload: DaymarkBackupPayload(version: 1, exportedAt: day(), entries: [record]))
        let merge = try await photoStore.importBackup(from: backup, mode: .merge, into: context)
        XCTAssertEqual(merge.imported, 0); XCTAssertEqual(merge.skipped, 1)
        XCTAssertEqual(photoStore.originalData(for: existing), old)
        let overwrite = try await photoStore.importBackup(from: backup, mode: .overwrite, into: context)
        XCTAssertEqual(overwrite.imported, 1)
        XCTAssertEqual(existing.id, "local-id")
        XCTAssertEqual(photoStore.originalData(for: existing), new)
    }

    func testCompressedZIPRestoresAndChecksumCorruptionIsRejected() throws {
        let root = try directory(), photoStore = store(root)
        let data = try png()
        var record = metadata(day(), filename: "photo.png")
        record.dayKey = BackupCalendar.dayKey(for: day())
        record.imageByteCount = Int64(data.count)
        record.imageSHA256 = String(repeating: "f", count: 64)
        let payload = DaymarkBackupPayload(version: 3, exportedAt: day(), entries: [record])
        let url = root.appendingPathComponent("compressed.zip")
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for (path, contents) in [("entries.json", try BackupArchiveReader.encode(payload)), ("images/photo.png", data)] {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(contents.count), compressionMethod: .deflate) { offset, size in
                    contents.subdata(in: Int(offset)..<(Int(offset) + size))
                }
            }
        }
        XCTAssertThrowsError(try photoStore.parseBackup(from: url)) { error in
            guard case BackupError.damagedPhoto = error else { return XCTFail("Unexpected error: \(error)") }
        }
        record.imageSHA256 = BackupArchiveReader.hash(data)
        let validURL = root.appendingPathComponent("valid-compressed.zip")
        do {
            let archive = try Archive(url: validURL, accessMode: .create)
            for (path, contents) in [("entries.json", try BackupArchiveReader.encode(DaymarkBackupPayload(version: 3, exportedAt: day(), entries: [record]))), ("images/photo.png", data)] {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(contents.count), compressionMethod: .deflate) { offset, size in
                    contents.subdata(in: Int(offset)..<(Int(offset) + size))
                }
            }
        }
        let valid = try photoStore.parseBackup(from: validURL)
        defer { valid.cleanUp() }
        XCTAssertEqual(valid.imageData(named: "photo.png"), data)
    }

    func testUnsafeArchiveAndUnknownVersionAreRejected() throws {
        let root = try directory(), photoStore = store(root)
        let url = root.appendingPathComponent("unsafe.zip")
        let payload = DaymarkBackupPayload(version: 2, exportedAt: day(), entries: [])
        let archive = ZipArchive.create(entries: [.init(path: "entries.json", data: try BackupArchiveReader.encode(payload)), .init(path: "../outside.jpg", data: Data())])
        try archive.write(to: url)
        XCTAssertThrowsError(try photoStore.parseBackup(from: url))
        XCTAssertThrowsError(try BackupArchiveReader.validateMetadata(DaymarkBackupPayload(version: 99, exportedAt: day(), entries: [])))
    }

    func testRestoredDaySurvivesTimezoneChange() throws {
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var destination = Calendar(identifier: .gregorian)
        destination.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sourceDay = sourceCalendar.date(from: DateComponents(year: 2025, month: 7, day: 10))!
        var entry = metadata(sourceDay)
        entry.dayKey = "2025-07-10"
        let restored = try BackupCalendar.restoredDay(entry, calendar: destination)
        XCTAssertEqual(BackupCalendar.dayKey(for: restored, calendar: destination), "2025-07-10")
    }

    func testCancelledImportKeepsExistingLibrary() async throws {
        let photoStore = store(try directory()), modelContainer = try container(), context = ModelContext(modelContainer)
        let data = try png()
        let existing = PhotoEntry(day: day(), imageData: data, caption: "Before")
        context.insert(existing); try context.save()
        var record = metadata(day()); record.legacyImageData = data
        let backup = BackupContents(payload: DaymarkBackupPayload(version: 1, exportedAt: day(), entries: [record]))
        var task: Task<BackupImportSummary, Error>?
        task = Task {
            try await photoStore.importBackup(from: backup, mode: .overwrite, into: context) { _, _ in
                task?.cancel() // Cancel after a replacement's files have been staged.
            }
        }
        do { _ = try await task!.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(existing.caption, "Before")
        XCTAssertEqual(photoStore.originalData(for: existing), data)
    }

    func testMigrationKeepsLegacyOriginalAvailableForUpgradeFallback() async throws {
        let root = try directory(), photoStore = store(root), modelContainer = try container(), context = ModelContext(modelContainer)
        let data = try png()
        let legacyURL = root.appendingPathComponent("legacy/old.png")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: legacyURL)
        let entry = PhotoEntry(day: day(), imageFilename: "old.png")
        context.insert(entry); try context.save()
        await photoStore.migrateLegacyLibraryIfNeeded(in: context)
        XCTAssertEqual(entry.imageFilename, "old.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let modern = try XCTUnwrap(entry.localOriginalFilename)
        try FileManager.default.removeItem(at: root.appendingPathComponent("originals").appendingPathComponent(modern))
        XCTAssertEqual(photoStore.originalData(for: entry), data)
    }
}

@MainActor
private final class BackupRemoteStore: OriginalPhotoRemoteStore {
    let id: String
    let data: Data
    let advertisedHash: String?
    var downloads: [String] = []
    var uploads = 0
    init(id: String, data: Data, advertisedHash: String? = nil) {
        self.id = id; self.data = data; self.advertisedHash = advertisedHash
    }
    func inventory() async throws -> [String: RemoteOriginalPhoto] {
        [id: RemoteOriginalPhoto(entryID: id, contentHash: advertisedHash ?? BackupArchiveReader.hash(data), byteCount: Int64(data.count), modifiedAt: .now)]
    }
    func download(entryID: String) async throws -> Data { downloads.append(entryID); return data }
    func upload(_ request: OriginalPhotoUploadRequest, overwrite: Bool) async throws { uploads += 1 }
}
