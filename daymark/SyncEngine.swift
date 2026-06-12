import CloudKit
import Foundation
import Observation
import SwiftData

struct SyncFailureItem: Codable, Equatable, Identifiable {
    let entryID: String
    let component: SyncComponent
    let message: String

    var id: String { "\(entryID):\(component.rawValue)" }
}

struct SyncConflictItem: Codable, Equatable, Identifiable {
    let entryID: String
    let day: Date
    let localBytes: Int64
    let remoteBytes: Int64
    let remoteIsPreserved: Bool

    var id: String { entryID }
}

struct SyncStatusSnapshot: Codable, Equatable {
    var isRunning = false
    var phase = "Idle"
    var pendingUploadCount = 0
    var pendingUploadBytes: Int64 = 0
    var pendingDownloadCount = 0
    var pendingDownloadBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var failures: [SyncFailureItem] = []
    var conflicts: [SyncConflictItem] = []
    var lastConfirmedAt: Date?
    var iCloudAvailable = false
}

@MainActor
@Observable
final class SyncEngineStatusStore {
    static let shared = SyncEngineStatusStore()

    private(set) var snapshot: SyncStatusSnapshot
    private let defaultsKey = "daymark.sync-engine.snapshot.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(SyncStatusSnapshot.self, from: data) {
            snapshot = decoded
            snapshot.isRunning = false
            snapshot.phase = "Idle"
        } else {
            snapshot = SyncStatusSnapshot()
        }
    }

    func begin(phase: String, entries: [PhotoEntry]) {
        snapshot.isRunning = true
        snapshot.phase = phase
        snapshot.uploadedBytes = 0
        snapshot.downloadedBytes = 0
        refresh(entries: entries)
    }

    func setPhase(_ phase: String, entries: [PhotoEntry]) {
        snapshot.phase = phase
        refresh(entries: entries)
    }

    func addTransferred(uploaded: Int64 = 0, downloaded: Int64 = 0) {
        snapshot.uploadedBytes += uploaded
        snapshot.downloadedBytes += downloaded
        persist()
    }

    func finish(entries: [PhotoEntry], confirmed: Bool) {
        refresh(entries: entries)
        snapshot.isRunning = false
        snapshot.phase = snapshot.failures.isEmpty && snapshot.conflicts.isEmpty
            ? "Up to Date"
            : "Needs Attention"
        if confirmed {
            snapshot.lastConfirmedAt = .now
        }
        persist()
    }

    func setICloudAvailable(_ available: Bool) {
        snapshot.iCloudAvailable = available
        persist()
    }

    func refresh(entries: [PhotoEntry]) {
        var pendingUploadCount = 0
        var pendingUploadBytes: Int64 = 0
        var pendingDownloadCount = 0
        var pendingDownloadBytes: Int64 = 0
        var failures: [SyncFailureItem] = []
        var conflicts: [SyncConflictItem] = []

        for entry in entries {
            for component in SyncComponent.allCases {
                let state = entry.syncState(for: component)
                let bytes = byteCount(for: component, entry: entry)
                if [.localOnly, .pendingUpload, .uploading].contains(state) {
                    pendingUploadCount += 1
                    pendingUploadBytes += bytes
                }
                if [.pendingDownload, .downloading].contains(state) {
                    pendingDownloadCount += 1
                    pendingDownloadBytes += bytes
                }
                if state == .failed {
                    failures.append(
                        SyncFailureItem(
                            entryID: entry.id,
                            component: component,
                            message: entry.lastSyncErrorMessage ?? "Sync failed."
                        )
                    )
                }
            }

            if entry.originalSyncState == .conflict {
                conflicts.append(
                    SyncConflictItem(
                        entryID: entry.id,
                        day: entry.day,
                        localBytes: entry.originalByteCount ?? 0,
                        remoteBytes: entry.originalConflictRemoteByteCount ?? 0,
                        remoteIsPreserved: entry.originalConflictRemoteFilename != nil
                    )
                )
            }
        }

        snapshot.pendingUploadCount = pendingUploadCount
        snapshot.pendingUploadBytes = pendingUploadBytes
        snapshot.pendingDownloadCount = pendingDownloadCount
        snapshot.pendingDownloadBytes = pendingDownloadBytes
        snapshot.failures = failures
        snapshot.conflicts = conflicts.sorted { $0.day > $1.day }
        persist()
    }

    private func byteCount(for component: SyncComponent, entry: PhotoEntry) -> Int64 {
        switch component {
        case .metadata:
            Int64(entry.metadataVersionData?.count ?? 0)
        case .thumbnail:
            entry.thumbnailByteCount ?? 0
        case .viewPhoto:
            entry.viewPhotoByteCount ?? 0
        case .original:
            entry.originalByteCount ?? entry.originalConflictRemoteByteCount ?? 0
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

@MainActor
struct SyncEngine {
    private let metadataCoordinator: MetadataSyncCoordinator
    private let thumbnailCoordinator: ThumbnailPhotoSyncCoordinator
    private let viewPhotoCoordinator: ViewPhotoSyncCoordinator
    private let originalCoordinator: OriginalPhotoSyncCoordinator
    private let statusStore: SyncEngineStatusStore

    init() {
        metadataCoordinator = MetadataSyncCoordinator()
        thumbnailCoordinator = ThumbnailPhotoSyncCoordinator()
        viewPhotoCoordinator = ViewPhotoSyncCoordinator()
        originalCoordinator = OriginalPhotoSyncCoordinator()
        statusStore = .shared
    }

    init(
        metadataCoordinator: MetadataSyncCoordinator,
        thumbnailCoordinator: ThumbnailPhotoSyncCoordinator,
        viewPhotoCoordinator: ViewPhotoSyncCoordinator,
        originalCoordinator: OriginalPhotoSyncCoordinator,
        statusStore: SyncEngineStatusStore
    ) {
        self.metadataCoordinator = metadataCoordinator
        self.thumbnailCoordinator = thumbnailCoordinator
        self.viewPhotoCoordinator = viewPhotoCoordinator
        self.originalCoordinator = originalCoordinator
        self.statusStore = statusStore
    }

    func sync(
        entries initialEntries: [PhotoEntry],
        in modelContext: ModelContext,
        includeOriginals: Bool,
        originalLimits: OriginalPhotoSyncLimits = .manual
    ) async throws {
        statusStore.begin(phase: "Removing Deleted Entries", entries: initialEntries)
        statusStore.setICloudAvailable(await cloudAccountAvailable())
        await SyncDeletionCoordinator().flush()

        statusStore.setPhase("Checking Metadata", entries: initialEntries)

        let metadata = try await metadataCoordinator.sync(
            entries: initialEntries,
            in: modelContext
        )
        statusStore.addTransferred(
            uploaded: metadata.uploadedBytes,
            downloaded: metadata.downloadedBytes
        )

        let entries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
        statusStore.setPhase("Syncing Thumbnails", entries: entries)
        let thumbnails = try await thumbnailCoordinator.syncThumbnails(
            entries: entries,
            in: modelContext
        )
        statusStore.addTransferred(
            uploaded: thumbnails.uploadedBytes,
            downloaded: thumbnails.downloadedBytes
        )

        statusStore.setPhase("Syncing Viewing Photos", entries: entries)
        let viewing = try await viewPhotoCoordinator.reconcile(
            entries: entries,
            in: modelContext
        )
        statusStore.addTransferred(uploaded: viewing.transferredBytes)

        if includeOriginals {
            statusStore.setPhase("Syncing Originals", entries: entries)
            let originals = try await originalCoordinator.syncOriginals(
                entries: entries,
                in: modelContext,
                limits: originalLimits
            )
            statusStore.addTransferred(
                uploaded: originals.uploadedBytes,
                downloaded: originals.downloadedBytes
            )
        }

        let confirmed = entries.allSatisfy { entry in
            SyncComponent.allCases.allSatisfy { component in
                entry.syncState(for: component) != .failed
            }
        }
        statusStore.finish(entries: entries, confirmed: confirmed)
        if entries.allSatisfy({ $0.imageData == nil && $0.thumbnailData == nil }) {
            LegacySyncMigration.recordSuccessfulMigrationCycle()
        }
#if DEBUG
        let snapshot = statusStore.snapshot
        print(
            "DAYMARK_SYNC_ENGINE_RESULT " +
            "pendingUpload=\(snapshot.pendingUploadCount) " +
            "pendingUploadBytes=\(snapshot.pendingUploadBytes) " +
            "pendingDownload=\(snapshot.pendingDownloadCount) " +
            "pendingDownloadBytes=\(snapshot.pendingDownloadBytes) " +
            "uploadedBytes=\(snapshot.uploadedBytes) " +
            "downloadedBytes=\(snapshot.downloadedBytes) " +
            "failures=\(snapshot.failures.count) " +
            "conflicts=\(snapshot.conflicts.count)"
        )
#endif
    }

    func refresh(entries: [PhotoEntry]) async {
        statusStore.setICloudAvailable(await cloudAccountAvailable())
        statusStore.refresh(entries: entries)
    }

    private func cloudAccountAvailable() async -> Bool {
        do {
            return try await CKContainer(
                identifier: "iCloud.com.shizhengcao.Daymark"
            ).accountStatus() == .available
        } catch {
            return false
        }
    }
}
