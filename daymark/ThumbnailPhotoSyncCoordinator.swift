import CloudKit
import CryptoKit
import Foundation
import SwiftData

struct RemoteThumbnailPhoto: Equatable {
    let entryID: String
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

struct ThumbnailPhotoUploadRequest {
    let entryID: String
    let data: Data
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

protocol ThumbnailPhotoRemoteStore {
    func inventory() async throws -> [String: RemoteThumbnailPhoto]
    func upload(_ request: ThumbnailPhotoUploadRequest, overwrite: Bool) async throws
    func upload(_ requests: [ThumbnailPhotoUploadRequest], overwrite: Bool) async throws
    func download(entryID: String) async throws -> Data
    func download(entryIDs: [String]) async throws -> [String: Data]
}

extension ThumbnailPhotoRemoteStore {
    func upload(_ requests: [ThumbnailPhotoUploadRequest], overwrite: Bool) async throws {
        for request in requests {
            try await upload(request, overwrite: overwrite)
        }
    }

    func download(entryIDs: [String]) async throws -> [String: Data] {
        var downloads: [String: Data] = [:]
        for entryID in entryIDs {
            downloads[entryID] = try await download(entryID: entryID)
        }
        return downloads
    }
}

struct ThumbnailPhotoSyncSummary {
    var uploadedCount = 0
    var downloadedCount = 0
    var skippedCount = 0
    var failedCount = 0
    var transferredBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
}

@MainActor
struct ThumbnailPhotoSyncCoordinator {
    private let remoteStore: any ThumbnailPhotoRemoteStore
    private let photoStore: PhotoStore

    init() {
        remoteStore = CloudKitThumbnailPhotoStore()
        photoStore = PhotoStore()
    }

    init(
        remoteStore: any ThumbnailPhotoRemoteStore,
        photoStore: PhotoStore
    ) {
        self.remoteStore = remoteStore
        self.photoStore = photoStore
    }

    func syncThumbnails(
        entries: [PhotoEntry],
        in modelContext: ModelContext
    ) async throws -> ThumbnailPhotoSyncSummary {
#if DEBUG
        print("DAYMARK_THUMBNAIL_SYNC_START entries=\(entries.count)")
#endif
        let remoteInventory = try await remoteStore.inventory()
#if DEBUG
        print("DAYMARK_THUMBNAIL_SYNC_INVENTORY records=\(remoteInventory.count)")
#endif
        var summary = ThumbnailPhotoSyncSummary()
        var newUploads: [(PhotoEntry, ThumbnailPhotoUploadRequest)] = []
        var replacementUploads: [(PhotoEntry, ThumbnailPhotoUploadRequest)] = []
        var downloads: [(PhotoEntry, RemoteThumbnailPhoto)] = []

        for entry in entries {
            let localData = photoStore.thumbnailData(for: entry)
            let remote = remoteInventory[entry.id]

            switch (localData, remote) {
            case let (.some(data), .none):
                newUploads.append((entry, uploadRequest(data, entry: entry)))

            case let (.none, .some(remote)):
                downloads.append((entry, remote))

            case let (.some(data), .some(remote)):
                let localHash = entry.thumbnailContentHash ?? Self.hash(data)
                if localHash == remote.contentHash {
                    markSynced(entry)
                    summary.skippedCount += 1
                } else if (entry.thumbnailModifiedAt ?? .distantPast) >= remote.modifiedAt {
                    replacementUploads.append((entry, uploadRequest(data, entry: entry)))
                } else {
                    downloads.append((entry, remote))
                }

            case (.none, .none):
                summary.skippedCount += 1
            }
        }

#if DEBUG
        print(
            "DAYMARK_THUMBNAIL_SYNC_PLAN " +
            "newUploads=\(newUploads.count) " +
            "replacements=\(replacementUploads.count) " +
            "downloads=\(downloads.count)"
        )
#endif
        await upload(newUploads, overwrite: false, summary: &summary)
        await upload(replacementUploads, overwrite: true, summary: &summary)
        await download(downloads, summary: &summary)
        try? modelContext.save()
        return summary
    }

    private func uploadRequest(
        _ data: Data,
        entry: PhotoEntry
    ) -> ThumbnailPhotoUploadRequest {
        let contentHash = entry.thumbnailContentHash ?? Self.hash(data)
        let byteCount = Int64(data.count)
        let modifiedAt = entry.thumbnailModifiedAt ?? .now
        entry.thumbnailByteCount = byteCount
        entry.thumbnailContentHash = contentHash
        entry.thumbnailModifiedAt = modifiedAt
        return ThumbnailPhotoUploadRequest(
            entryID: entry.id,
            data: data,
            contentHash: contentHash,
            byteCount: byteCount,
            modifiedAt: modifiedAt
        )
    }

    private func upload(
        _ candidates: [(entry: PhotoEntry, request: ThumbnailPhotoUploadRequest)],
        overwrite: Bool,
        summary: inout ThumbnailPhotoSyncSummary
    ) async {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            setState(.pendingUpload, for: candidate.entry)
            setState(.uploading, for: candidate.entry)
        }

        do {
            try await remoteStore.upload(candidates.map(\.request), overwrite: overwrite)
            for candidate in candidates {
                markSynced(candidate.entry)
                summary.uploadedCount += 1
                summary.transferredBytes += candidate.request.byteCount
                summary.uploadedBytes += candidate.request.byteCount
            }
        } catch {
            for candidate in candidates {
                markFailed(candidate.entry, message: error.localizedDescription)
                summary.failedCount += 1
            }
        }
    }

    private func download(
        _ candidates: [(entry: PhotoEntry, remote: RemoteThumbnailPhoto)],
        summary: inout ThumbnailPhotoSyncSummary
    ) async {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            setState(.pendingDownload, for: candidate.entry)
            setState(.downloading, for: candidate.entry)
        }

        do {
            let downloadedData = try await remoteStore.download(
                entryIDs: candidates.map { $0.entry.id }
            )
            for candidate in candidates {
                guard let data = downloadedData[candidate.entry.id] else {
                    throw ThumbnailPhotoSyncError.missingRemoteAsset
                }
                guard Self.hash(data) == candidate.remote.contentHash else {
                    throw ThumbnailPhotoSyncError.downloadHashMismatch
                }
                try photoStore.storeDownloadedThumbnail(
                    data,
                    remote: candidate.remote,
                    for: candidate.entry
                )
                markSynced(candidate.entry)
                summary.downloadedCount += 1
                summary.transferredBytes += Int64(data.count)
                summary.downloadedBytes += Int64(data.count)
            }
        } catch {
            for candidate in candidates {
                markFailed(candidate.entry, message: error.localizedDescription)
                summary.failedCount += 1
            }
        }
    }

    private func markSynced(_ entry: PhotoEntry) {
        setState(.synced, for: entry)
        if entry.lastSyncErrorComponentRaw == SyncComponent.thumbnail.rawValue {
            entry.lastSyncErrorComponentRaw = nil
            entry.lastSyncErrorMessage = nil
        }
    }

    private func markFailed(_ entry: PhotoEntry, message: String) {
        setState(.failed, for: entry, errorMessage: message)
    }

    private func setState(
        _ state: SyncState,
        for entry: PhotoEntry,
        errorMessage: String? = nil
    ) {
        if !entry.transitionSyncState(
            for: .thumbnail,
            to: state,
            errorMessage: errorMessage
        ) {
            entry.thumbnailSyncState = state
            entry.syncStateUpdatedAt = .now
            if state == .failed {
                entry.lastSyncErrorComponentRaw = SyncComponent.thumbnail.rawValue
                entry.lastSyncErrorMessage = errorMessage
            }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudKitThumbnailPhotoStore: ThumbnailPhotoRemoteStore {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark"),
        zoneName: String = SyncEnvironment.zoneName("DaymarkThumbnailAssetsV1")
    ) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func inventory() async throws -> [String: RemoteThumbnailPhoto] {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return [:]
        }

        var inventory: [String: RemoteThumbnailPhoto] = [:]
        var token: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let changes = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: ["contentHash", "byteCount", "modifiedAt"]
            )
            for result in changes.modificationResultsByID.values {
                guard case .success(let modification) = result else { continue }
                let record = modification.record
                guard record.recordType == "DaymarkThumbnailPhoto",
                      let contentHash = record["contentHash"] as? String,
                      let byteCount = record["byteCount"] as? Int64,
                      let modifiedAt = record["modifiedAt"] as? Date else { continue }
                inventory[record.recordID.recordName] = RemoteThumbnailPhoto(
                    entryID: record.recordID.recordName,
                    contentHash: contentHash,
                    byteCount: byteCount,
                    modifiedAt: modifiedAt
                )
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }

        return inventory
    }

    func upload(_ request: ThumbnailPhotoUploadRequest, overwrite: Bool) async throws {
        try await upload([request], overwrite: overwrite)
    }

    func upload(_ requests: [ThumbnailPhotoUploadRequest], overwrite: Bool) async throws {
        try await ensureZoneExists()

        let chunks = requests.chunked(maximumCount: 200)
        for (index, chunk) in chunks.enumerated() {
            var temporaryURLs: [URL] = []
            defer {
                for url in temporaryURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            let records = try chunk.map { request in
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("thumb")
                try request.data.write(to: temporaryURL, options: .atomic)
                temporaryURLs.append(temporaryURL)

                let recordID = CKRecord.ID(recordName: request.entryID, zoneID: zoneID)
                let record = CKRecord(recordType: "DaymarkThumbnailPhoto", recordID: recordID)
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
#if DEBUG
            print(
                "DAYMARK_THUMBNAIL_UPLOAD_BATCH " +
                "completed=\(index + 1)/\(chunks.count) records=\(chunk.count)"
            )
#endif
        }
    }

    func download(entryID: String) async throws -> Data {
        guard let data = try await download(entryIDs: [entryID])[entryID] else {
            throw ThumbnailPhotoSyncError.missingRemoteAsset
        }
        return data
    }

    func download(entryIDs: [String]) async throws -> [String: Data] {
        var downloads: [String: Data] = [:]
        let chunks = entryIDs.chunked(maximumCount: 200)
        for (index, chunk) in chunks.enumerated() {
            let recordIDs = chunk.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            let results = try await database.records(for: recordIDs, desiredKeys: ["asset"])
            for (recordID, result) in results {
                let record = try result.get()
                guard let asset = record["asset"] as? CKAsset,
                      let fileURL = asset.fileURL else {
                    throw ThumbnailPhotoSyncError.missingRemoteAsset
                }
                downloads[recordID.recordName] = try Data(
                    contentsOf: fileURL,
                    options: .mappedIfSafe
                )
            }
#if DEBUG
            print(
                "DAYMARK_THUMBNAIL_DOWNLOAD_BATCH " +
                "completed=\(index + 1)/\(chunks.count) records=\(chunk.count)"
            )
#endif
        }
        return downloads
    }

    private func ensureZoneExists() async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }
}

enum ThumbnailPhotoSyncError: LocalizedError {
    case missingRemoteAsset
    case downloadHashMismatch

    var errorDescription: String? {
        switch self {
        case .missingRemoteAsset:
            return "The iCloud thumbnail asset is missing."
        case .downloadHashMismatch:
            return "The downloaded thumbnail did not pass integrity verification."
        }
    }
}

extension Array {
    func chunked(maximumCount: Int) -> [ArraySlice<Element>] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map {
            self[$0..<Swift.min($0 + maximumCount, count)]
        }
    }
}
