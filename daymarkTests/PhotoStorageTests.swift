import XCTest
import CryptoKit
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import Daymark_Journal

@MainActor
final class PhotoStorageTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    func testLargePhotoIsReencodedToBoundedHEICKeepingCaptureMetadata() throws {
        let source = try makeCameraPhoto(width: 4_032, height: 3_024)
        XCTAssertGreaterThan(source.count, 2_000_000)

        let stored = try PhotoEncoding.storedOriginal(from: source)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(stored as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.heic.identifier)
        XCTAssertEqual(max(width, height), 3_072)
        XCTAssertLessThan(stored.count, source.count / 2)
        XCTAssertFalse(PhotoEncoding.isOverLimits(stored))
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2025:06:01 08:30:00")
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 31.23, accuracy: 0.001)
    }

    func testSmallPhotoIsKeptByteForByte() throws {
        let source = try makeCameraPhoto(width: 640, height: 480, quality: 0.8)
        XCTAssertEqual(try PhotoEncoding.storedOriginal(from: source), source)
    }

    func testViewPhotoRenditionFitsBudget() throws {
        let source = try makeCameraPhoto(width: 4_032, height: 3_024)
        let view = try PhotoEncoding.rendition(from: source, profile: PhotoEncoding.viewPhoto)
        XCTAssertLessThanOrEqual(view.count, 600_000)
    }

    func testCompactionReplacesOversizedOriginalAndMarksItForUpload() async throws {
        let fixture = try makeFixture()
        let source = try makeCameraPhoto(width: 4_032, height: 3_024)
        let stored = try OriginalPhotoFileStore(directoryURL: fixture.originals).write(source, ownerID: "e1")
        let entry = PhotoEntry(id: "e1", day: .now, localOriginalFilename: stored.filename,
                               originalByteCount: stored.byteCount, originalContentHash: stored.contentHash,
                               originalSyncState: .synced)
        entry.originalLastSyncedHash = stored.contentHash
        fixture.context.insert(entry)
        try fixture.context.save()

        let count = await fixture.store.compactLibraryIfNeeded(for: [entry], in: fixture.context)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(entry.photoStorageVersion, PhotoEncoding.storageVersion)
        XCTAssertEqual(entry.originalCompactedFromHash, stored.contentHash)
        XCTAssertNotEqual(entry.originalContentHash, stored.contentHash)
        XCTAssertEqual(entry.originalLastSyncedHash, stored.contentHash)
        XCTAssertEqual(entry.originalSyncState, .pendingUpload)
        XCTAssertEqual(entry.viewPhotoSyncState, .localOnly)
        let data = try XCTUnwrap(fixture.store.originalData(for: entry))
        XCTAssertEqual(PhotoEncoding.hash(data), entry.originalContentHash)
        XCTAssertEqual(Int64(data.count), entry.originalByteCount)
        XCTAssertNotNil(fixture.store.viewPhotoData(for: entry))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.originals.appendingPathComponent(stored.filename).path))

        let again = await fixture.store.compactLibraryIfNeeded(for: [entry], in: fixture.context)
        XCTAssertEqual(again, 0)
    }

    func testCompactionSkipsEntriesInConflict() async throws {
        let fixture = try makeFixture()
        let source = try makeCameraPhoto(width: 4_032, height: 3_024)
        let stored = try OriginalPhotoFileStore(directoryURL: fixture.originals).write(source, ownerID: "e1")
        let entry = PhotoEntry(id: "e1", day: .now, localOriginalFilename: stored.filename,
                               originalContentHash: stored.contentHash, originalSyncState: .conflict)
        fixture.context.insert(entry)

        let count = await fixture.store.compactLibraryIfNeeded(for: [entry], in: fixture.context)

        XCTAssertEqual(count, 0)
        XCTAssertEqual(entry.originalContentHash, stored.contentHash)
        XCTAssertNil(entry.photoStorageVersion)
    }

    func testSyncTakesSiblingDeviceCompactionInsteadOfConflict() async throws {
        let fixture = try makeFixture()
        let local = try OriginalPhotoFileStore(directoryURL: fixture.originals)
            .write(Data("compacted-here".utf8), ownerID: "e1")
        let entry = PhotoEntry(id: "e1", day: .now, localOriginalFilename: local.filename,
                               originalContentHash: local.contentHash, originalSyncState: .pendingUpload)
        let sourceHash = String(repeating: "a", count: 64)
        entry.originalLastSyncedHash = sourceHash
        entry.originalCompactedFromHash = sourceHash
        fixture.context.insert(entry)
        let remoteData = Data("compacted-elsewhere".utf8)
        let remote = OriginalStoreStub(
            inventory: ["e1": RemoteOriginalPhoto(entryID: "e1", contentHash: PhotoEncoding.hash(remoteData),
                                                  byteCount: Int64(remoteData.count), modifiedAt: .now,
                                                  derivedFromHash: sourceHash)],
            downloads: ["e1": remoteData]
        )

        let summary = try await OriginalPhotoSyncCoordinator(remoteStore: remote, photoStore: fixture.store)
            .syncOriginals(entries: [entry], in: fixture.context, limits: .unlimited)

        XCTAssertEqual(summary.conflictCount, 0)
        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertTrue(remote.uploads.isEmpty)
        XCTAssertEqual(fixture.store.originalData(for: entry), remoteData)
        XCTAssertEqual(entry.originalSyncState, .synced)
    }

    func testSyncUploadsCompactionOverItsSourceAndRecordsDerivation() async throws {
        let fixture = try makeFixture()
        let local = try OriginalPhotoFileStore(directoryURL: fixture.originals)
            .write(Data("compacted-here".utf8), ownerID: "e1")
        let entry = PhotoEntry(id: "e1", day: .now, localOriginalFilename: local.filename,
                               originalContentHash: local.contentHash, originalSyncState: .localOnly)
        let sourceHash = String(repeating: "c", count: 64)
        entry.originalCompactedFromHash = sourceHash // never recorded a sync base
        fixture.context.insert(entry)
        let remote = OriginalStoreStub(
            inventory: ["e1": RemoteOriginalPhoto(entryID: "e1", contentHash: sourceHash,
                                                  byteCount: 5_000_000, modifiedAt: .now)]
        )

        let summary = try await OriginalPhotoSyncCoordinator(remoteStore: remote, photoStore: fixture.store)
            .syncOriginals(entries: [entry], in: fixture.context, limits: .unlimited)

        XCTAssertEqual(summary.conflictCount, 0)
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(remote.uploads.first?.overwrite, true)
        XCTAssertEqual(remote.uploads.first?.request.derivedFromHash, sourceHash)
        XCTAssertEqual(entry.originalLastSyncedHash, local.contentHash)
    }

    func testNewPhotoIsStoredInBoundedFormat() async throws {
        let fixture = try makeFixture()
        let source = try makeCameraPhoto(width: 4_032, height: 3_024, gps: false)
        let place = PhotoLocationOverride(latitude: 31.23, longitude: 121.47, city: "Shanghai",
                                          countryCode: "CN", countryName: "China")

        try await fixture.store.savePhotoData(source, for: Date(timeIntervalSince1970: 3_000),
                                              in: fixture.context, locationOverride: place)

        let entry = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<PhotoEntry>()).first)
        let data = try XCTUnwrap(fixture.store.originalData(for: entry))
        XCTAssertFalse(PhotoEncoding.isOverLimits(data))
        XCTAssertEqual(entry.photoStorageVersion, PhotoEncoding.storageVersion)
        XCTAssertEqual(entry.originalContentHash, PhotoEncoding.hash(data))
        XCTAssertEqual(entry.latitude ?? 0, 31.23, accuracy: 0.001)
        XCTAssertNotNil(entry.captureDate)
    }

    // MARK: - Helpers

    private func makeFixture() throws -> (context: ModelContext, store: PhotoStore, originals: URL) {
        let schema = Schema([PhotoEntry.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directories.append(root)
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        let store = PhotoStore(
            originalsDirectoryURL: originals,
            thumbnailsDirectoryURL: root.appendingPathComponent("thumbs", isDirectory: true),
            viewPhotosDirectoryURL: root.appendingPathComponent("views", isDirectory: true),
            conflictPhotosDirectoryURL: root.appendingPathComponent("conflicts", isDirectory: true),
            legacyPhotosDirectoryURL: root.appendingPathComponent("legacy", isDirectory: true),
            flushPendingDeletions: {}
        )
        return (ModelContext(container), store, originals)
    }

    /// A noisy, camera-sized JPEG with EXIF capture date and GPS, which
    /// compresses about as badly as a real photo does.
    private func makeCameraPhoto(width: Int, height: Int, quality: CGFloat = 0.95, gps: Bool = true) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 0x1234_5678
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = UInt8(truncatingIfNeeded: seed >> 24) / 4
                let i = (y * width + x) * 4
                pixels[i] = UInt8(truncatingIfNeeded: x * 255 / width) &+ noise
                pixels[i + 1] = UInt8(truncatingIfNeeded: y * 255 / height) &+ noise
                pixels[i + 2] = 128 &+ noise
                pixels[i + 3] = 255
            }
        }
        let cgImage = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:06:01 08:30:00"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.23, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.47, kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        if !gps { properties.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

@MainActor
private final class OriginalStoreStub: OriginalPhotoRemoteStore {
    private(set) var uploads: [(request: OriginalPhotoUploadRequest, overwrite: Bool)] = []
    private let remoteInventory: [String: RemoteOriginalPhoto]
    private let downloads: [String: Data]

    init(inventory: [String: RemoteOriginalPhoto], downloads: [String: Data] = [:]) {
        remoteInventory = inventory
        self.downloads = downloads
    }

    func inventory() async throws -> [String: RemoteOriginalPhoto] { remoteInventory }

    func upload(_ request: OriginalPhotoUploadRequest, overwrite: Bool) async throws {
        uploads.append((request, overwrite))
    }

    func download(entryID: String) async throws -> Data {
        guard let data = downloads[entryID] else { throw OriginalPhotoSyncError.missingRemoteAsset }
        return data
    }
}
