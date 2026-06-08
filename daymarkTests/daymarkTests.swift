import XCTest
import CryptoKit
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

    func testOriginalSyncCoordinatorUploadsPendingOriginal() async throws {
        let fixture = try makeOriginalSyncFixture()
        let remoteStore = RecordingOriginalRemoteStore()
        let coordinator = OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        )

        let summary = try await coordinator.syncOriginals(
            entries: [fixture.entry],
            in: fixture.context,
            limits: .unlimited
        )

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(fixture.entry.originalSyncState, .synced)
        XCTAssertNil(fixture.entry.lastSyncErrorMessage)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(remoteStore.uploadRequests.first?.entryID, fixture.entry.id)
        XCTAssertEqual(remoteStore.uploadRequests.first?.data, fixture.data)
    }

    func testOriginalSyncCoordinatorRecordsUploadFailure() async throws {
        let fixture = try makeOriginalSyncFixture()
        let remoteStore = RecordingOriginalRemoteStore(uploadError: TestUploadError.offline)
        let coordinator = OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        )

        let summary = try await coordinator.syncOriginals(
            entries: [fixture.entry],
            in: fixture.context,
            limits: .unlimited
        )

        XCTAssertEqual(summary.uploadedCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(fixture.entry.originalSyncState, .failed)
        XCTAssertEqual(fixture.entry.lastSyncErrorComponentRaw, SyncComponent.original.rawValue)
        XCTAssertEqual(fixture.entry.lastSyncErrorMessage, TestUploadError.offline.localizedDescription)
    }

    func testOriginalSyncCoordinatorRejectsMissingLocalFile() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(
            day: .now,
            localOriginalFilename: "missing.image",
            originalByteCount: 100,
            originalContentHash: String(repeating: "a", count: 64),
            originalSyncState: .localOnly
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingOriginalRemoteStore()

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: PhotoStore(
                originalsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        ).syncOriginals(entries: [entry], in: context, limits: .unlimited)

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(entry.originalSyncState, .failed)
        XCTAssertEqual(entry.lastSyncErrorMessage, "The local original photo is missing.")
        XCTAssertTrue(remoteStore.uploadRequests.isEmpty)
    }

    func testOriginalSyncCoordinatorDownloadsRemoteOnlyOriginal() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = Data("remote-original".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = PhotoEntry(
            id: "remote-entry",
            day: .now,
            localOriginalFilename: "other-device.image",
            originalByteCount: Int64(data.count),
            originalContentHash: hash,
            originalSyncState: .synced
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingOriginalRemoteStore(
            inventory: [
                entry.id: RemoteOriginalPhoto(
                    entryID: entry.id,
                    contentHash: hash,
                    byteCount: Int64(data.count),
                    modifiedAt: .now
                )
            ],
            downloads: [entry.id: data]
        )
        let store = PhotoStore(originalsDirectoryURL: directoryURL)

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: store
        ).syncOriginals(entries: [entry], in: context, limits: .unlimited)

        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(entry.originalSyncState, .synced)
        XCTAssertEqual(store.originalData(for: entry), data)
        XCTAssertNotEqual(entry.localOriginalFilename, "other-device.image")
    }

    func testOriginalSyncCoordinatorMarksDifferentHashesAsConflict() async throws {
        let fixture = try makeOriginalSyncFixture()
        let remoteStore = RecordingOriginalRemoteStore(
            inventory: [
                fixture.entry.id: RemoteOriginalPhoto(
                    entryID: fixture.entry.id,
                    contentHash: String(repeating: "f", count: 64),
                    byteCount: 500,
                    modifiedAt: .now
                )
            ]
        )

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).syncOriginals(entries: [fixture.entry], in: fixture.context, limits: .unlimited)

        XCTAssertEqual(summary.conflictCount, 1)
        XCTAssertEqual(fixture.entry.originalSyncState, .conflict)
        XCTAssertEqual(
            fixture.entry.lastSyncErrorMessage,
            "This device and iCloud contain different original photos."
        )
        XCTAssertTrue(remoteStore.uploadRequests.isEmpty)
    }

    func testOriginalSyncCoordinatorDefersTransfersBeyondBatchLimit() async throws {
        let first = try makeOriginalSyncFixture(entryID: "first-entry")
        let secondData = Data("second-original".utf8)
        let secondFileStore = OriginalPhotoFileStore(directoryURL: first.directoryURL)
        let secondStored = try secondFileStore.write(secondData, ownerID: "second-entry")
        let secondEntry = PhotoEntry(
            id: "second-entry",
            day: .now.addingTimeInterval(1),
            localOriginalFilename: secondStored.filename,
            originalByteCount: secondStored.byteCount,
            originalContentHash: secondStored.contentHash,
            originalSyncState: .localOnly
        )
        first.context.insert(secondEntry)
        try first.context.save()
        let remoteStore = RecordingOriginalRemoteStore()

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: first.store
        ).syncOriginals(
            entries: [first.entry, secondEntry],
            in: first.context,
            limits: OriginalPhotoSyncLimits(
                maximumTransferCount: 1,
                maximumTransferredBytes: .max
            )
        )

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.deferredCount, 1)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(secondEntry.originalSyncState, .pendingUpload)
    }

    func testOriginalSyncCoordinatorCountsFailedAttemptsAgainstBatchLimit() async throws {
        let first = try makeOriginalSyncFixture(entryID: "failed-first")
        let secondData = Data("deferred-after-failure".utf8)
        let fileStore = OriginalPhotoFileStore(directoryURL: first.directoryURL)
        let secondStored = try fileStore.write(secondData, ownerID: "deferred-second")
        let secondEntry = PhotoEntry(
            id: "deferred-second",
            day: .now.addingTimeInterval(1),
            localOriginalFilename: secondStored.filename,
            originalByteCount: secondStored.byteCount,
            originalContentHash: secondStored.contentHash,
            originalSyncState: .localOnly
        )
        first.context.insert(secondEntry)
        try first.context.save()
        let remoteStore = RecordingOriginalRemoteStore(uploadError: TestUploadError.offline)

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: first.store
        ).syncOriginals(
            entries: [first.entry, secondEntry],
            in: first.context,
            limits: OriginalPhotoSyncLimits(
                maximumTransferCount: 1,
                maximumTransferredBytes: .max
            )
        )

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.deferredCount, 1)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(secondEntry.originalSyncState, .pendingUpload)
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

    private func makeOriginalSyncFixture(entryID: String = "sync-entry") throws -> (
        context: ModelContext,
        entry: PhotoEntry,
        store: PhotoStore,
        data: Data,
        directoryURL: URL
    ) {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = OriginalPhotoFileStore(directoryURL: directoryURL)
        let data = Data("original-sync-payload".utf8)
        let stored = try fileStore.write(data, ownerID: entryID)
        let entry = PhotoEntry(
            id: entryID,
            day: .now,
            localOriginalFilename: stored.filename,
            originalByteCount: stored.byteCount,
            originalContentHash: stored.contentHash,
            originalSyncState: .localOnly
        )
        context.insert(entry)
        try context.save()
        return (context, entry, PhotoStore(originalsDirectoryURL: directoryURL), data, directoryURL)
    }
}

@MainActor
private final class RecordingOriginalRemoteStore: OriginalPhotoRemoteStore {
    private(set) var uploadRequests: [OriginalPhotoUploadRequest] = []
    private let remoteInventory: [String: RemoteOriginalPhoto]
    private let downloads: [String: Data]
    private let uploadError: Error?

    init(
        inventory: [String: RemoteOriginalPhoto] = [:],
        downloads: [String: Data] = [:],
        uploadError: Error? = nil
    ) {
        remoteInventory = inventory
        self.downloads = downloads
        self.uploadError = uploadError
    }

    func inventory() async throws -> [String: RemoteOriginalPhoto] {
        remoteInventory
    }

    func upload(_ request: OriginalPhotoUploadRequest) async throws {
        uploadRequests.append(request)
        if let uploadError {
            throw uploadError
        }
    }

    func download(entryID: String) async throws -> Data {
        guard let data = downloads[entryID] else {
            throw OriginalPhotoSyncError.missingRemoteAsset
        }
        return data
    }
}

private enum TestUploadError: LocalizedError {
    case offline

    var errorDescription: String? {
        "Network offline"
    }
}
