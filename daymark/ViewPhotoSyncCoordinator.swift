import CloudKit
import CryptoKit
import Foundation
import SwiftData

struct RemoteViewPhoto: Equatable {
    let entryID: String
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

struct ViewPhotoUploadRequest {
    let entryID: String
    let data: Data
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

struct DownloadedViewPhoto {
    let remote: RemoteViewPhoto
    let data: Data
}

protocol ViewPhotoRemoteStore {
    func inventory() async throws -> [String: RemoteViewPhoto]
    func upload(_ requests: [ViewPhotoUploadRequest], overwrite: Bool) async throws
    func download(entryID: String) async throws -> DownloadedViewPhoto
}

struct ViewPhotoSyncSummary {
    var uploadedCount = 0
    var pendingDownloadCount = 0
    var failedCount = 0
    var transferredBytes: Int64 = 0
    var pendingDownloadBytes: Int64 = 0
}

@MainActor
struct ViewPhotoSyncCoordinator {
    private let remoteStore: any ViewPhotoRemoteStore
    private let photoStore: PhotoStore

    init() {
        remoteStore = CloudKitViewPhotoStore()
        photoStore = PhotoStore()
    }

    init(
        remoteStore: any ViewPhotoRemoteStore,
        photoStore: PhotoStore
    ) {
        self.remoteStore = remoteStore
        self.photoStore = photoStore
    }

    func reconcile(
        entries: [PhotoEntry],
        in modelContext: ModelContext
    ) async throws -> ViewPhotoSyncSummary {
        #if DEBUG
        print("DAYMARK_VIEW_SYNC_START entries=\(entries.count)")
        #endif
        let remoteInventory = try await remoteStore.inventory()
        #if DEBUG
        print("DAYMARK_VIEW_SYNC_INVENTORY records=\(remoteInventory.count)")
        #endif
        var summary = ViewPhotoSyncSummary()
        var newUploads: [(PhotoEntry, ViewPhotoUploadRequest)] = []
        var replacementUploads: [(PhotoEntry, ViewPhotoUploadRequest)] = []

        for entry in entries {
            let localData = photoStore.viewPhotoData(for: entry)
            let remote = remoteInventory[entry.id]

            switch (localData, remote) {
            case let (.some(data), .none):
                newUploads.append((entry, uploadRequest(data, for: entry)))

            case let (.none, .some(remote)):
                markPendingDownload(entry, remote: remote)
                summary.pendingDownloadCount += 1
                summary.pendingDownloadBytes += remote.byteCount

            case let (.some(data), .some(remote)):
                let localHash = entry.viewPhotoContentHash ?? Self.hash(data)
                if localHash == remote.contentHash {
                    apply(remote, to: entry)
                    setState(.synced, for: entry)
                } else if (entry.viewPhotoModifiedAt ?? .distantPast) >= remote.modifiedAt {
                    replacementUploads.append((entry, uploadRequest(data, for: entry)))
                } else {
                    photoStore.removeLocalViewPhoto(for: entry)
                    markPendingDownload(entry, remote: remote)
                    summary.pendingDownloadCount += 1
                    summary.pendingDownloadBytes += remote.byteCount
                }

            case (.none, .none):
                break
            }
        }

        #if DEBUG
        let uploadBytes = (newUploads + replacementUploads)
            .reduce(Int64(0)) { $0 + $1.1.byteCount }
        print(
            "DAYMARK_VIEW_SYNC_PLAN uploads=\(newUploads.count + replacementUploads.count) " +
            "uploadBytes=\(uploadBytes) pendingDownloads=\(summary.pendingDownloadCount) " +
            "pendingBytes=\(summary.pendingDownloadBytes)"
        )
        #endif
        await upload(newUploads, overwrite: false, summary: &summary)
        await upload(replacementUploads, overwrite: true, summary: &summary)
        try? modelContext.save()
        #if DEBUG
        print(
            "DAYMARK_VIEW_SYNC_DONE uploaded=\(summary.uploadedCount) " +
            "failed=\(summary.failedCount) bytes=\(summary.transferredBytes)"
        )
        #endif
        return summary
    }

    func downloadOnDemand(
        entry: PhotoEntry,
        in modelContext: ModelContext
    ) async throws -> Int64 {
        if let data = photoStore.viewPhotoData(for: entry) {
            return Int64(data.count)
        }

        setState(.pendingDownload, for: entry)
        setState(.downloading, for: entry)
        try? modelContext.save()

        do {
            let downloaded = try await remoteStore.download(entryID: entry.id)
            guard Self.hash(downloaded.data) == downloaded.remote.contentHash else {
                throw ViewPhotoSyncError.downloadHashMismatch
            }
            try photoStore.storeDownloadedViewPhoto(
                downloaded.data,
                remote: downloaded.remote,
                for: entry
            )
            setState(.synced, for: entry)
            try modelContext.save()
            return Int64(downloaded.data.count)
        } catch {
            setState(.failed, for: entry, errorMessage: error.localizedDescription)
            try? modelContext.save()
            throw error
        }
    }

    private func uploadRequest(
        _ data: Data,
        for entry: PhotoEntry
    ) -> ViewPhotoUploadRequest {
        let contentHash = entry.viewPhotoContentHash ?? Self.hash(data)
        let byteCount = Int64(data.count)
        let modifiedAt = entry.viewPhotoModifiedAt ?? .now
        entry.viewPhotoContentHash = contentHash
        entry.viewPhotoByteCount = byteCount
        entry.viewPhotoModifiedAt = modifiedAt
        return ViewPhotoUploadRequest(
            entryID: entry.id,
            data: data,
            contentHash: contentHash,
            byteCount: byteCount,
            modifiedAt: modifiedAt
        )
    }

    private func upload(
        _ candidates: [(entry: PhotoEntry, request: ViewPhotoUploadRequest)],
        overwrite: Bool,
        summary: inout ViewPhotoSyncSummary
    ) async {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            setState(.pendingUpload, for: candidate.entry)
            setState(.uploading, for: candidate.entry)
        }

        do {
            try await remoteStore.upload(candidates.map(\.request), overwrite: overwrite)
            for candidate in candidates {
                setState(.synced, for: candidate.entry)
                summary.uploadedCount += 1
                summary.transferredBytes += candidate.request.byteCount
            }
        } catch {
            for candidate in candidates {
                setState(.failed, for: candidate.entry, errorMessage: error.localizedDescription)
                summary.failedCount += 1
            }
        }
    }

    private func markPendingDownload(_ entry: PhotoEntry, remote: RemoteViewPhoto) {
        apply(remote, to: entry)
        setState(.pendingDownload, for: entry)
    }

    private func apply(_ remote: RemoteViewPhoto, to entry: PhotoEntry) {
        entry.viewPhotoContentHash = remote.contentHash
        entry.viewPhotoByteCount = remote.byteCount
        entry.viewPhotoModifiedAt = remote.modifiedAt
    }

    private func setState(
        _ state: SyncState,
        for entry: PhotoEntry,
        errorMessage: String? = nil
    ) {
        if !entry.transitionSyncState(
            for: .viewPhoto,
            to: state,
            errorMessage: errorMessage
        ) {
            entry.viewPhotoSyncState = state
            entry.syncStateUpdatedAt = .now
            if state == .failed {
                entry.lastSyncErrorComponentRaw = SyncComponent.viewPhoto.rawValue
                entry.lastSyncErrorMessage = errorMessage
            }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudKitViewPhotoStore: ViewPhotoRemoteStore {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark"),
        zoneName: String = "DaymarkViewAssetsV1"
    ) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func inventory() async throws -> [String: RemoteViewPhoto] {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return [:]
        }

        var inventory: [String: RemoteViewPhoto] = [:]
        var token: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let changes = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: ["contentHash", "byteCount", "modifiedAt"]
            )
            for result in changes.modificationResultsByID.values {
                guard case .success(let modification) = result,
                      let remote = remoteViewPhoto(from: modification.record) else {
                    continue
                }
                inventory[remote.entryID] = remote
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }

        return inventory
    }

    func upload(_ requests: [ViewPhotoUploadRequest], overwrite: Bool) async throws {
        try await ensureZoneExists()

        for chunk in requests.chunked(maximumCount: 100) {
            var temporaryURLs: [URL] = []
            defer {
                for url in temporaryURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            let records = try chunk.map { request in
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("view")
                try request.data.write(to: temporaryURL, options: .atomic)
                temporaryURLs.append(temporaryURL)

                let recordID = CKRecord.ID(recordName: request.entryID, zoneID: zoneID)
                let record = CKRecord(recordType: "DaymarkViewPhoto", recordID: recordID)
                record["asset"] = CKAsset(fileURL: temporaryURL)
                record["contentHash"] = request.contentHash as CKRecordValue
                record["byteCount"] = request.byteCount as CKRecordValue
                record["modifiedAt"] = request.modifiedAt as CKRecordValue
                return record
            }

            try await withCheckedThrowingContinuation { continuation in
                let operation = CKModifyRecordsOperation(recordsToSave: records)
                operation.savePolicy = overwrite ? .allKeys : .changedKeys
                operation.isAtomic = true
                operation.qualityOfService = .utility
                operation.modifyRecordsResultBlock = { result in
                    continuation.resume(with: result.map { _ in () })
                }
                database.add(operation)
            }
        }
    }

    func download(entryID: String) async throws -> DownloadedViewPhoto {
        let recordID = CKRecord.ID(recordName: entryID, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        guard let remote = remoteViewPhoto(from: record),
              let asset = record["asset"] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw ViewPhotoSyncError.missingRemoteAsset
        }
        return DownloadedViewPhoto(
            remote: remote,
            data: try Data(contentsOf: fileURL, options: .mappedIfSafe)
        )
    }

    private func remoteViewPhoto(from record: CKRecord) -> RemoteViewPhoto? {
        guard record.recordType == "DaymarkViewPhoto",
              let contentHash = record["contentHash"] as? String,
              let byteCount = record["byteCount"] as? Int64,
              let modifiedAt = record["modifiedAt"] as? Date else {
            return nil
        }
        return RemoteViewPhoto(
            entryID: record.recordID.recordName,
            contentHash: contentHash,
            byteCount: byteCount,
            modifiedAt: modifiedAt
        )
    }

    private func ensureZoneExists() async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }
}

enum ViewPhotoSyncError: LocalizedError {
    case missingRemoteAsset
    case downloadHashMismatch

    var errorDescription: String? {
        switch self {
        case .missingRemoteAsset:
            return "The iCloud viewing photo is not available yet."
        case .downloadHashMismatch:
            return "The downloaded viewing photo did not pass integrity verification."
        }
    }
}
