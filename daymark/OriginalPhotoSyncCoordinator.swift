import CloudKit
import CryptoKit
import Foundation
import SwiftData

struct RemoteOriginalPhoto: Equatable {
    let entryID: String
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

struct OriginalPhotoUploadRequest {
    let entryID: String
    let data: Data
    let contentHash: String
    let byteCount: Int64
    let modifiedAt: Date
}

protocol OriginalPhotoRemoteStore {
    func inventory() async throws -> [String: RemoteOriginalPhoto]
    func upload(_ request: OriginalPhotoUploadRequest, overwrite: Bool) async throws
    func download(entryID: String) async throws -> Data
}

extension OriginalPhotoRemoteStore {
    func upload(_ request: OriginalPhotoUploadRequest) async throws {
        try await upload(request, overwrite: false)
    }
}

struct OriginalPhotoSyncLimits: Sendable {
    let maximumTransferCount: Int
    let maximumTransferredBytes: Int64

    nonisolated static let manual = OriginalPhotoSyncLimits(
        maximumTransferCount: 10,
        maximumTransferredBytes: 100 * 1_024 * 1_024
    )

    nonisolated static let unlimited = OriginalPhotoSyncLimits(
        maximumTransferCount: .max,
        maximumTransferredBytes: .max
    )
}

struct OriginalPhotoSyncSummary {
    var uploadedCount = 0
    var downloadedCount = 0
    var conflictCount = 0
    var failedCount = 0
    var skippedCount = 0
    var deferredCount = 0
    var transferredBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var attemptedTransferCount = 0
    var attemptedBytes: Int64 = 0
}

@MainActor
struct OriginalPhotoSyncCoordinator {
    private let remoteStore: any OriginalPhotoRemoteStore
    private let photoStore: PhotoStore

    init() {
        remoteStore = CloudKitOriginalPhotoStore()
        photoStore = PhotoStore()
    }

    init(
        remoteStore: any OriginalPhotoRemoteStore,
        photoStore: PhotoStore
    ) {
        self.remoteStore = remoteStore
        self.photoStore = photoStore
    }

    func syncOriginals(
        entries: [PhotoEntry],
        in modelContext: ModelContext
    ) async throws -> OriginalPhotoSyncSummary {
        try await syncOriginals(entries: entries, in: modelContext, limits: .manual)
    }

    func syncOriginals(
        entries: [PhotoEntry],
        in modelContext: ModelContext,
        limits: OriginalPhotoSyncLimits
    ) async throws -> OriginalPhotoSyncSummary {
        let remoteInventory = try await remoteStore.inventory()
        var summary = OriginalPhotoSyncSummary()

        for entry in entries {
            let localData = photoStore.originalData(for: entry)
            let remote = remoteInventory[entry.id]

            if let localData, let remote {
                let localHash = entry.originalContentHash ?? Self.hash(localData)
                if localHash == remote.contentHash {
                    markSynced(entry, contentHash: localHash)
                    summary.skippedCount += 1
                } else if let baseHash = entry.originalLastSyncedHash,
                          remote.contentHash == baseHash {
                    let byteCount = Int64(localData.count)
                    guard canTransfer(byteCount, summary: summary, limits: limits) else {
                        _ = entry.transitionSyncState(for: .original, to: .pendingUpload)
                        summary.deferredCount += 1
                        continue
                    }
                    _ = entry.transitionSyncState(for: .original, to: .pendingUpload)
                    _ = entry.transitionSyncState(for: .original, to: .uploading)
                    summary.attemptedTransferCount += 1
                    summary.attemptedBytes += byteCount
                    do {
                        try await remoteStore.upload(
                            OriginalPhotoUploadRequest(
                                entryID: entry.id,
                                data: localData,
                                contentHash: localHash,
                                byteCount: byteCount,
                                modifiedAt: .now
                            ),
                            overwrite: true
                        )
                        markSynced(entry, contentHash: localHash)
                        summary.uploadedCount += 1
                        summary.transferredBytes += byteCount
                        summary.uploadedBytes += byteCount
                    } catch {
                        markFailed(entry, message: error.localizedDescription)
                        summary.failedCount += 1
                    }
                } else if let baseHash = entry.originalLastSyncedHash,
                          localHash == baseHash {
                    guard canTransfer(remote.byteCount, summary: summary, limits: limits) else {
                        _ = entry.transitionSyncState(for: .original, to: .pendingDownload)
                        summary.deferredCount += 1
                        continue
                    }
                    _ = entry.transitionSyncState(for: .original, to: .pendingDownload)
                    _ = entry.transitionSyncState(for: .original, to: .downloading)
                    summary.attemptedTransferCount += 1
                    summary.attemptedBytes += remote.byteCount
                    do {
                        let data = try await remoteStore.download(entryID: entry.id)
                        guard Self.hash(data) == remote.contentHash else {
                            throw OriginalPhotoSyncError.downloadHashMismatch
                        }
                        try photoStore.storeDownloadedOriginal(data, for: entry)
                        markSynced(entry, contentHash: remote.contentHash)
                        summary.downloadedCount += 1
                        summary.transferredBytes += Int64(data.count)
                        summary.downloadedBytes += Int64(data.count)
                    } catch {
                        markFailed(entry, message: error.localizedDescription)
                        summary.failedCount += 1
                    }
                } else {
                    do {
                        let filename: String
                        if entry.originalConflictRemoteHash == remote.contentHash,
                           photoStore.conflictOriginalData(for: entry) != nil,
                           let existing = entry.originalConflictRemoteFilename {
                            filename = existing
                        } else {
                            let data = try await remoteStore.download(entryID: entry.id)
                            guard Self.hash(data) == remote.contentHash else {
                                throw OriginalPhotoSyncError.downloadHashMismatch
                            }
                            filename = try photoStore.storeConflictOriginal(data, for: entry).filename
                            summary.transferredBytes += Int64(data.count)
                            summary.downloadedBytes += Int64(data.count)
                        }
                        markConflict(entry, remote: remote, filename: filename)
                        summary.conflictCount += 1
                    } catch {
                        markFailed(entry, message: error.localizedDescription)
                        summary.failedCount += 1
                    }
                }
                try? modelContext.save()
                continue
            }

            if localData == nil, let remote {
                guard canTransfer(remote.byteCount, summary: summary, limits: limits) else {
                    _ = entry.transitionSyncState(for: .original, to: .pendingDownload)
                    summary.deferredCount += 1
                    continue
                }

                _ = entry.transitionSyncState(for: .original, to: .pendingDownload)
                _ = entry.transitionSyncState(for: .original, to: .downloading)
                summary.attemptedTransferCount += 1
                summary.attemptedBytes += remote.byteCount
                try? modelContext.save()

                do {
                    let data = try await remoteStore.download(entryID: entry.id)
                    guard Self.hash(data) == remote.contentHash else {
                        throw OriginalPhotoSyncError.downloadHashMismatch
                    }
                    try photoStore.storeDownloadedOriginal(data, for: entry)
                    markSynced(entry, contentHash: remote.contentHash)
                    summary.downloadedCount += 1
                    summary.transferredBytes += Int64(data.count)
                    summary.downloadedBytes += Int64(data.count)
                } catch {
                    markFailed(entry, message: error.localizedDescription)
                    summary.failedCount += 1
                }
                try? modelContext.save()
                continue
            }

            guard let localData else {
                if entry.localOriginalFilename != nil || entry.originalContentHash != nil {
                    markFailed(entry, message: OriginalPhotoSyncError.missingLocalOriginal.localizedDescription)
                    summary.failedCount += 1
                    try? modelContext.save()
                } else {
                    summary.skippedCount += 1
                }
                continue
            }

            let byteCount = Int64(localData.count)
            guard canTransfer(byteCount, summary: summary, limits: limits) else {
                _ = entry.transitionSyncState(for: .original, to: .pendingUpload)
                summary.deferredCount += 1
                continue
            }

            let contentHash = entry.originalContentHash ?? Self.hash(localData)
            entry.originalByteCount = byteCount
            entry.originalContentHash = contentHash
            _ = entry.transitionSyncState(for: .original, to: .pendingUpload)
            _ = entry.transitionSyncState(for: .original, to: .uploading)
            summary.attemptedTransferCount += 1
            summary.attemptedBytes += byteCount
            try? modelContext.save()

            do {
                try await remoteStore.upload(
                    OriginalPhotoUploadRequest(
                        entryID: entry.id,
                        data: localData,
                        contentHash: contentHash,
                        byteCount: byteCount,
                        modifiedAt: entry.syncStateUpdatedAt ?? .now
                    )
                )
                _ = entry.transitionSyncState(for: .original, to: .synced)
                entry.originalLastSyncedHash = contentHash
                summary.uploadedCount += 1
                summary.transferredBytes += byteCount
                summary.uploadedBytes += byteCount
            } catch {
                markFailed(entry, message: error.localizedDescription)
                summary.failedCount += 1
            }
            try? modelContext.save()
        }

        return summary
    }

    private func canTransfer(
        _ byteCount: Int64,
        summary: OriginalPhotoSyncSummary,
        limits: OriginalPhotoSyncLimits
    ) -> Bool {
        guard summary.attemptedTransferCount < limits.maximumTransferCount else { return false }
        return byteCount <= limits.maximumTransferredBytes - summary.attemptedBytes
    }

    private func markSynced(_ entry: PhotoEntry, contentHash: String) {
        if !entry.transitionSyncState(for: .original, to: .synced) {
            entry.originalSyncState = .synced
            entry.syncStateUpdatedAt = .now
        }
        if entry.lastSyncErrorComponentRaw == SyncComponent.original.rawValue {
            entry.lastSyncErrorComponentRaw = nil
            entry.lastSyncErrorMessage = nil
        }
        entry.originalLastSyncedHash = contentHash
    }

    private func markConflict(
        _ entry: PhotoEntry,
        remote: RemoteOriginalPhoto,
        filename: String
    ) {
        if !entry.transitionSyncState(for: .original, to: .conflict) {
            entry.originalSyncState = .conflict
            entry.syncStateUpdatedAt = .now
        }
        entry.lastSyncErrorComponentRaw = SyncComponent.original.rawValue
        entry.lastSyncErrorMessage = OriginalPhotoSyncError.contentConflict.localizedDescription
        entry.recordOriginalConflict(remote: remote, filename: filename)
    }

    private func markFailed(_ entry: PhotoEntry, message: String) {
        if !entry.transitionSyncState(for: .original, to: .failed, errorMessage: message) {
            entry.originalSyncState = .failed
            entry.syncStateUpdatedAt = .now
            entry.lastSyncErrorComponentRaw = SyncComponent.original.rawValue
            entry.lastSyncErrorMessage = message
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudKitOriginalPhotoStore: OriginalPhotoRemoteStore {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark"),
        zoneName: String = "DaymarkOriginalAssetsV1"
    ) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func inventory() async throws -> [String: RemoteOriginalPhoto] {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return [:]
        }

        var inventory: [String: RemoteOriginalPhoto] = [:]
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
                guard record.recordType == "DaymarkOriginalPhoto",
                      let contentHash = record["contentHash"] as? String,
                      let byteCount = record["byteCount"] as? Int64,
                      let modifiedAt = record["modifiedAt"] as? Date else { continue }
                inventory[record.recordID.recordName] = RemoteOriginalPhoto(
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

    func upload(_ request: OriginalPhotoUploadRequest, overwrite: Bool) async throws {
        try await ensureZoneExists()

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("image")
        try request.data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let recordID = CKRecord.ID(recordName: request.entryID, zoneID: zoneID)
        let record = CKRecord(recordType: "DaymarkOriginalPhoto", recordID: recordID)
        record["asset"] = CKAsset(fileURL: temporaryURL)
        record["contentHash"] = request.contentHash as CKRecordValue
        record["byteCount"] = request.byteCount as CKRecordValue
        record["modifiedAt"] = request.modifiedAt as CKRecordValue

        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record])
            operation.savePolicy = overwrite ? .allKeys : .changedKeys
            operation.isAtomic = true
            operation.modifyRecordsResultBlock = { result in
                continuation.resume(with: result.map { _ in () })
            }
            database.add(operation)
        }
    }

    func download(entryID: String) async throws -> Data {
        let recordID = CKRecord.ID(recordName: entryID, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        guard let asset = record["asset"] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw OriginalPhotoSyncError.missingRemoteAsset
        }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    private func ensureZoneExists() async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }
}

@MainActor
struct OriginalPhotoConflictResolver {
    private let remoteStore: any OriginalPhotoRemoteStore
    private let photoStore: PhotoStore

    init() {
        remoteStore = CloudKitOriginalPhotoStore()
        photoStore = PhotoStore()
    }

    init(
        remoteStore: any OriginalPhotoRemoteStore,
        photoStore: PhotoStore
    ) {
        self.remoteStore = remoteStore
        self.photoStore = photoStore
    }

    func keepLocal(_ entry: PhotoEntry, in modelContext: ModelContext) async throws {
        guard entry.originalSyncState == .conflict,
              let data = photoStore.originalData(for: entry) else {
            throw OriginalPhotoSyncError.missingLocalOriginal
        }

        let contentHash = Self.hash(data)
        let byteCount = Int64(data.count)
        try await remoteStore.upload(
            OriginalPhotoUploadRequest(
                entryID: entry.id,
                data: data,
                contentHash: contentHash,
                byteCount: byteCount,
                modifiedAt: .now
            ),
            overwrite: true
        )

        entry.originalContentHash = contentHash
        entry.originalByteCount = byteCount
        entry.originalLastSyncedHash = contentHash
        photoStore.removeConflictOriginal(for: entry)
        entry.clearOriginalConflict(resolution: .keptLocal)
        markResolved(entry)
        try modelContext.save()
    }

    func useICloud(_ entry: PhotoEntry, in modelContext: ModelContext) async throws {
        guard entry.originalSyncState == .conflict,
              let remoteHash = entry.originalConflictRemoteHash else {
            throw OriginalPhotoSyncError.missingConflictSnapshot
        }

        let data: Data
        if let preserved = photoStore.conflictOriginalData(for: entry) {
            data = preserved
        } else {
            data = try await remoteStore.download(entryID: entry.id)
        }
        guard Self.hash(data) == remoteHash else {
            throw OriginalPhotoSyncError.downloadHashMismatch
        }

        try photoStore.storeDownloadedOriginal(data, for: entry)
        entry.originalLastSyncedHash = remoteHash
        photoStore.removeConflictOriginal(for: entry)
        entry.clearOriginalConflict(resolution: .usedICloud)
        markResolved(entry)
        try modelContext.save()
    }

    private func markResolved(_ entry: PhotoEntry) {
        entry.originalSyncState = .synced
        entry.syncStateUpdatedAt = .now
        entry.lastSyncErrorComponentRaw = nil
        entry.lastSyncErrorMessage = nil
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum OriginalPhotoSyncError: LocalizedError, Equatable {
    case missingLocalOriginal
    case missingRemoteAsset
    case downloadHashMismatch
    case contentConflict
    case missingConflictSnapshot

    var errorDescription: String? {
        switch self {
        case .missingLocalOriginal:
            "The local original photo is missing."
        case .missingRemoteAsset:
            "The iCloud original photo asset is missing."
        case .downloadHashMismatch:
            "The downloaded original did not match its iCloud checksum."
        case .contentConflict:
            "This device and iCloud contain different original photos."
        case .missingConflictSnapshot:
            "The conflict details are missing. Sync again before resolving it."
        }
    }
}
