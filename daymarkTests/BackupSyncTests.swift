import SwiftData
import UIKit
import XCTest
@testable import Daymark_Journal

@MainActor
final class BackupSyncTests: XCTestCase {
    func testEmptyLibraryRestoreIsNotOverwrittenByOlderSameIDCloudMetadata() async throws {
        let fixture = try await exportedBackup()
        defer { fixture.contents.cleanUp() }
        let target = photoStore(at: try temporaryDirectory())
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        let imported = try await target.importBackup(from: fixture.contents, mode: .merge, into: context)
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoEntry>()).first)
        XCTAssertEqual(imported.imported, 1)
        XCTAssertEqual(restored.id, fixture.id)
        XCTAssertEqual(MetadataSnapshot(entry: restored), fixture.snapshot)

        // The same entry already exists in the cloud, but contains older text
        // and location. An explicit restore must remain a local change that
        // can be written back, even though this device has no sync baseline.
        let remote = BackupSyncMetadataStore(record: olderRemoteRecord(for: restored))
        let coordinator = MetadataSyncCoordinator(remoteStore: remote, deviceID: "restore-test-device")
        let summary = try await coordinator.sync(entries: [restored], in: context)

        XCTAssertEqual(MetadataSnapshot(entry: restored), fixture.snapshot,
                       "The first sync must not silently replace restored metadata with an older cloud copy")
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(remote.records[restored.id]?.metadata.snapshot, fixture.snapshot)
        XCTAssertEqual(restored.metadataSyncState, .synced)
        XCTAssertTrue(remote.deletedEntryIDs.isEmpty)

        // A subsequent ordinary edit must also be recognized and uploaded.
        restored.caption = "导入后的新记录 🌿"
        restored.city = "Kyoto"
        let edited = MetadataSnapshot(entry: restored)
        let editedSummary = try await coordinator.sync(entries: [restored], in: context)
        XCTAssertEqual(editedSummary.uploadedCount, 1)
        XCTAssertEqual(remote.records[restored.id]?.metadata.snapshot, edited)
        XCTAssertEqual(restored.caption, "导入后的新记录 🌿")
        XCTAssertEqual(restored.city, "Kyoto")
    }

    func testOverwriteRestoreWithExistingSyncBaselineWritesRestoredMetadataBack() async throws {
        let fixture = try await exportedBackup()
        defer { fixture.contents.cleanUp() }
        let target = photoStore(at: try temporaryDirectory())
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let existing = PhotoEntry(id: fixture.id, day: fixture.snapshot.day)
        let olderRecord = olderRemoteRecord(for: existing)
        olderRecord.metadata.snapshot.apply(to: existing)
        context.insert(existing)
        let remote = BackupSyncMetadataStore(record: olderRecord)
        let coordinator = MetadataSyncCoordinator(remoteStore: remote, deviceID: "restore-test-device")
        _ = coordinator.captureLocalChanges(for: existing, at: Date(timeIntervalSince1970: 100))
        try context.save()

        let imported = try await target.importBackup(from: fixture.contents, mode: .overwrite, into: context)
        XCTAssertEqual(imported.imported, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoEntry>()).count, 1)
        XCTAssertEqual(existing.id, fixture.id)
        XCTAssertEqual(MetadataSnapshot(entry: existing), fixture.snapshot)

        let summary = try await coordinator.sync(entries: [existing], in: context)
        XCTAssertEqual(MetadataSnapshot(entry: existing), fixture.snapshot)
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(remote.records[existing.id]?.metadata.snapshot, fixture.snapshot)
        XCTAssertEqual(existing.metadataSyncState, .synced)
        XCTAssertTrue(remote.deletedEntryIDs.isEmpty)
    }

    func testRestoreAllocatesNewIdentityWhileOldIdentityHasPendingDeletion() async throws {
        let fixture = try await exportedBackup()
        defer { fixture.contents.cleanUp() }
        let target = photoStore(at: try temporaryDirectory())
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        PendingSyncDeletionStore.add(entryID: fixture.id)
        defer { PendingSyncDeletionStore.remove(entryIDs: [fixture.id]) }

        let imported = try await target.importBackup(from: fixture.contents, mode: .merge, into: context)
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PhotoEntry>()).first)
        XCTAssertEqual(imported.imported, 1)
        XCTAssertNotEqual(restored.id, fixture.id,
                          "A restore must not reuse an identity that an in-flight cloud deletion can still delete")
        XCTAssertEqual(MetadataSnapshot(entry: restored), fixture.snapshot)
        XCTAssertTrue(PendingSyncDeletionStore.pendingEntryIDs().contains(fixture.id),
                      "The old identity must remain pending until its deletion is confirmed")

        let remote = BackupSyncMetadataStore()
        let summary = try await MetadataSyncCoordinator(remoteStore: remote, deviceID: "restore-test-device")
            .sync(entries: [restored], in: context)
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(remote.uploadedEntryIDs, [restored.id])
        XCTAssertNil(remote.records[fixture.id])
        XCTAssertEqual(remote.records[restored.id]?.metadata.snapshot, fixture.snapshot)
        XCTAssertTrue(PendingSyncDeletionStore.pendingEntryIDs().contains(fixture.id))
        XCTAssertTrue(remote.deletedEntryIDs.isEmpty)
    }

    func testOverwriteRestoreRefreshesAllVersionsEvenWhenBackupMatchesLocalBaseline() async throws {
        let fixture = try await exportedBackup()
        defer { fixture.contents.cleanUp() }
        let target = photoStore(at: try temporaryDirectory())
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let existing = PhotoEntry(id: fixture.id, day: fixture.snapshot.day)
        fixture.snapshot.apply(to: existing)
        context.insert(existing)
        let remote = BackupSyncMetadataStore(record: olderRemoteRecord(for: existing))
        let coordinator = MetadataSyncCoordinator(remoteStore: remote, deviceID: "restore-test-device")
        _ = coordinator.captureLocalChanges(for: existing, at: Date(timeIntervalSince1970: 100))
        try context.save()

        // The backup happens to match the last local baseline. The cloud has
        // a later revision (time 200) with different text and location, but
        // the explicit restore is a newer choice than both old revisions.
        let imported = try await target.importBackup(from: fixture.contents, mode: .overwrite, into: context)
        XCTAssertEqual(imported.imported, 1)
        XCTAssertEqual(MetadataSnapshot(entry: existing), fixture.snapshot)

        let summary = try await coordinator.sync(entries: [existing], in: context)
        XCTAssertEqual(MetadataSnapshot(entry: existing), fixture.snapshot,
                       "Restore must refresh versions even for fields whose value already matched the local baseline")
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(remote.records[existing.id]?.metadata.snapshot, fixture.snapshot)
        XCTAssertEqual(existing.metadataSyncState, .synced)
        XCTAssertTrue(remote.deletedEntryIDs.isEmpty)
    }

    private func exportedBackup() async throws -> (contents: BackupContents, id: String, snapshot: MetadataSnapshot) {
        let source = photoStore(at: try temporaryDirectory())
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2025, month: 7, day: 10)))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { renderer in
            UIColor.green.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let entry = PhotoEntry(
            day: day,
            imageData: try XCTUnwrap(image.pngData()),
            captureDate: day.addingTimeInterval(123.125),
            latitude: 35.6762,
            longitude: 139.6503,
            timezone: "Asia/Tokyo",
            countryCode: "JP",
            countryName: "Japan",
            city: "Tokyo",
            caption: "备份中的回忆：雨后的街角 🌿"
        )
        context.insert(entry)
        try context.save()
        let export = try await source.makeBackupExportItem(from: [entry], in: context, allowCloudDownload: false)
        defer { export.cleanUp() }
        return (try source.parseBackup(from: export.url), entry.id, MetadataSnapshot(entry: entry))
    }

    private func olderRemoteRecord(for entry: PhotoEntry) -> RemoteMetadataRecord {
        let cloudEntry = PhotoEntry(
            id: entry.id,
            day: entry.day,
            captureDate: entry.day.addingTimeInterval(60),
            latitude: 48.8566,
            longitude: 2.3522,
            timezone: "Europe/Paris",
            countryCode: "FR",
            countryName: "France",
            city: "Paris",
            caption: "Older cloud caption"
        )
        let version = MetadataFieldVersion(modifiedAt: Date(timeIntervalSince1970: 200), deviceID: "old-cloud-device")
        let versions = Dictionary(uniqueKeysWithValues: VersionedMetadata.fieldNames.map { ($0, version) })
        return RemoteMetadataRecord(entryID: entry.id, metadata: VersionedMetadata(snapshot: MetadataSnapshot(entry: cloudEntry), versions: versions))
    }

    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaymarkBackupSync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func photoStore(at root: URL) -> PhotoStore {
        PhotoStore(
            originalsDirectoryURL: root.appendingPathComponent("originals"),
            thumbnailsDirectoryURL: root.appendingPathComponent("thumbnails"),
            viewPhotosDirectoryURL: root.appendingPathComponent("views"),
            conflictPhotosDirectoryURL: root.appendingPathComponent("conflicts"),
            legacyPhotosDirectoryURL: root.appendingPathComponent("legacy")
        )
    }
}

@MainActor
private final class BackupSyncMetadataStore: MetadataRemoteStore {
    private(set) var records: [String: RemoteMetadataRecord]
    private(set) var deletedEntryIDs: [String] = []
    private(set) var uploadedEntryIDs: [String] = []

    init(record: RemoteMetadataRecord? = nil) {
        records = record.map { [$0.entryID: $0] } ?? [:]
    }

    func inventory() async throws -> [String: RemoteMetadataRecord] { records }

    func upload(_ uploaded: [RemoteMetadataRecord]) async throws {
        for record in uploaded {
            uploadedEntryIDs.append(record.entryID)
            records[record.entryID] = record
        }
    }

    func delete(entryIDs: [String]) async throws {
        deletedEntryIDs.append(contentsOf: entryIDs)
        for id in entryIDs { records.removeValue(forKey: id) }
    }
}
