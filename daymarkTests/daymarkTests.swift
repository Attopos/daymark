import XCTest
import SwiftData
import UIKit
@testable import Daymark_Journal

@MainActor
final class daymarkTests: XCTestCase {
    func testNewEntriesStartUntracked() {
        let entry = PhotoEntry(day: Date())

        XCTAssertEqual(entry.metadataSyncState, .untracked)
        XCTAssertEqual(entry.thumbnailSyncState, .untracked)
        XCTAssertEqual(entry.originalSyncState, .untracked)
        XCTAssertEqual(entry.overallSyncState, .untracked)
    }

    func testOverallStateUsesMostActionableComponent() {
        XCTAssertEqual(
            SyncStateMachine.overallState(
                metadata: .synced,
                thumbnail: .pendingDownload,
                original: .uploading
            ),
            .uploading
        )
        XCTAssertEqual(
            SyncStateMachine.overallState(
                metadata: .failed,
                thumbnail: .conflict,
                original: .uploading
            ),
            .conflict
        )
    }

    func testTransitionRecordsAndClearsComponentError() {
        let entry = PhotoEntry(day: Date(), metadataSyncState: .pendingUpload)
        let failureDate = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            entry.transitionSyncState(
                for: .metadata,
                to: .failed,
                at: failureDate,
                errorMessage: "Network unavailable"
            )
        )
        XCTAssertEqual(entry.metadataSyncState, .failed)
        XCTAssertEqual(entry.syncStateUpdatedAt, failureDate)
        XCTAssertEqual(entry.lastSyncErrorComponentRaw, SyncComponent.metadata.rawValue)
        XCTAssertEqual(entry.lastSyncErrorMessage, "Network unavailable")

        XCTAssertTrue(entry.transitionSyncState(for: .metadata, to: .pendingUpload))
        XCTAssertNil(entry.lastSyncErrorComponentRaw)
        XCTAssertNil(entry.lastSyncErrorMessage)
    }

    func testInvalidTransitionDoesNotMutateEntry() {
        let entry = PhotoEntry(day: Date(), originalSyncState: .untracked)

        XCTAssertFalse(entry.transitionSyncState(for: .original, to: .uploading))
        XCTAssertEqual(entry.originalSyncState, .untracked)
        XCTAssertNil(entry.syncStateUpdatedAt)
    }

    func testOriginalPhotoFileStoreWritesReadsAndRemovesData() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = OriginalPhotoFileStore(directoryURL: directoryURL)
        let data = Data("daymark-original".utf8)
        let stored = try store.write(data, ownerID: "entry-1")

        XCTAssertEqual(stored.byteCount, Int64(data.count))
        XCTAssertEqual(stored.contentHash.count, 64)
        XCTAssertTrue(stored.filename.hasSuffix(".image"))
        XCTAssertEqual(try store.read(filename: stored.filename), data)

        let duplicate = try store.write(data, ownerID: "entry-1")
        XCTAssertEqual(duplicate.filename, stored.filename)

        try store.remove(filename: stored.filename)
        XCTAssertThrowsError(try store.read(filename: stored.filename))
    }

    func testOriginalPhotoFileStoreRejectsUnsafeFilename() {
        let store = OriginalPhotoFileStore(
            directoryURL: FileManager.default.temporaryDirectory
        )

        XCTAssertThrowsError(try store.read(filename: "../outside.image"))
    }

    func testComponentSyncStatesPersistIndependently() throws {
        let container = try makeInMemoryContainer()
        let writeContext = ModelContext(container)
        let entry = PhotoEntry(
            day: Date(timeIntervalSince1970: 1_000),
            metadataSyncState: .synced,
            thumbnailSyncState: .pendingDownload,
            originalSyncState: .localOnly
        )
        writeContext.insert(entry)
        try writeContext.save()

        let readContext = ModelContext(container)
        let entries = try readContext.fetch(FetchDescriptor<PhotoEntry>())
        let persistedEntry = try XCTUnwrap(entries.first)

        XCTAssertEqual(persistedEntry.metadataSyncState, .synced)
        XCTAssertEqual(persistedEntry.thumbnailSyncState, .pendingDownload)
        XCTAssertEqual(persistedEntry.originalSyncState, .localOnly)
        XCTAssertEqual(persistedEntry.overallSyncState, .pendingDownload)
    }

    func testPhotoStoreKeepsOriginalOutsideSwiftDataAndRemovesItOnDelete() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = PhotoStore(originalsDirectoryURL: directoryURL)
        let imageData = try makeJPEGData()

        try await store.savePhotoData(
            imageData,
            for: Date(timeIntervalSince1970: 2_000),
            in: context
        )

        let entries = try context.fetch(FetchDescriptor<PhotoEntry>())
        let entry = try XCTUnwrap(entries.first)
        let filename = try XCTUnwrap(entry.localOriginalFilename)

        XCTAssertNil(entry.imageData)
        XCTAssertNotNil(entry.thumbnailData)
        XCTAssertEqual(entry.originalByteCount, Int64(imageData.count))
        XCTAssertEqual(entry.originalContentHash?.count, 64)
        XCTAssertEqual(entry.originalSyncState, .localOnly)
        XCTAssertEqual(store.originalData(for: entry), imageData)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent(filename).path
        ))

        try store.deleteEntry(entry, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<PhotoEntry>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent(filename).path
        ))
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }
}
