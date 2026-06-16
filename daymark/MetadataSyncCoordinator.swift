import CloudKit
import Foundation
import SwiftData

struct MetadataSnapshot: Codable, Equatable {
    var day: Date
    var captureDate: Date?
    var latitude: Double?
    var longitude: Double?
    var timezone: String?
    var countryCode: String?
    var countryName: String?
    var city: String?
    var caption: String?

    init(entry: PhotoEntry) {
        day = entry.day
        captureDate = entry.captureDate
        latitude = entry.latitude
        longitude = entry.longitude
        timezone = entry.timezone
        countryCode = entry.countryCode
        countryName = entry.countryName
        city = entry.city
        caption = entry.caption
    }

    func apply(to entry: PhotoEntry) {
        entry.day = day
        entry.captureDate = captureDate
        entry.latitude = latitude
        entry.longitude = longitude
        entry.timezone = timezone
        entry.countryCode = countryCode
        entry.countryName = countryName
        entry.city = city
        entry.caption = caption
    }
}

struct MetadataFieldVersion: Codable, Equatable, Comparable {
    let modifiedAt: Date
    let deviceID: String

    static func < (lhs: MetadataFieldVersion, rhs: MetadataFieldVersion) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt < rhs.modifiedAt
        }
        return lhs.deviceID < rhs.deviceID
    }
}

struct VersionedMetadata: Codable, Equatable {
    var snapshot: MetadataSnapshot
    var versions: [String: MetadataFieldVersion]

    static let fieldNames = [
        "day", "captureDate", "latitude", "longitude", "timezone",
        "countryCode", "countryName", "city", "caption",
    ]
}

struct RemoteMetadataRecord: Equatable {
    let entryID: String
    let metadata: VersionedMetadata
}

protocol MetadataRemoteStore {
    func inventory() async throws -> [String: RemoteMetadataRecord]
    func upload(_ records: [RemoteMetadataRecord]) async throws
    func delete(entryIDs: [String]) async throws
}

struct MetadataSyncSummary {
    var uploadedCount = 0
    var mergedCount = 0
    var downloadedCount = 0
    var failedCount = 0
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
}

@MainActor
struct MetadataSyncCoordinator {
    private let remoteStore: any MetadataRemoteStore
    private let deviceID: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        remoteStore = CloudKitMetadataStore()
        deviceID = SyncDeviceIdentity.current
    }

    init(remoteStore: any MetadataRemoteStore, deviceID: String) {
        self.remoteStore = remoteStore
        self.deviceID = deviceID
    }

    func sync(
        entries: [PhotoEntry],
        in modelContext: ModelContext
    ) async throws -> MetadataSyncSummary {
        var summary = MetadataSyncSummary()
        var localByID: [String: PhotoEntry] = [:]
        for entry in entries where localByID[entry.id] == nil {
            localByID[entry.id] = entry
        }
        let uniqueEntries = Array(localByID.values)
        var remoteByID = try await remoteStore.inventory()
        var localByDay: [Date: PhotoEntry] = [:]
        for entry in uniqueEntries {
            let day = Calendar.current.startOfDay(for: entry.day)
            if localByDay[day] == nil {
                localByDay[day] = entry
            }
        }
        let staleRemoteIDs = remoteByID.values.compactMap { remote -> String? in
            // Debug/test sentinels (dated year 2100+) leaked into CloudKit and
            // must never be resurrected; delete them from the cloud outright.
            if remote.metadata.snapshot.day >= PhotoEntry.sentinelDayCutoff {
                return remote.entryID
            }
            let day = Calendar.current.startOfDay(for: remote.metadata.snapshot.day)
            guard let local = localByDay[day], local.id != remote.entryID else { return nil }
            return remote.entryID
        }
        if !staleRemoteIDs.isEmpty {
            try await remoteStore.delete(entryIDs: staleRemoteIDs)
            for entryID in staleRemoteIDs {
                remoteByID.removeValue(forKey: entryID)
            }
        }
        var uploads: [RemoteMetadataRecord] = []

        for entry in uniqueEntries {
            let remote = remoteByID[entry.id]
            let local = captureLocalChanges(
                for: entry,
                at: entry.metadataVersionData == nil && remote != nil ? .distantPast : .now
            )
            guard let remote else {
                uploads.append(RemoteMetadataRecord(entryID: entry.id, metadata: local))
                setState(.pendingUpload, for: entry)
                continue
            }

            let merged = merge(local: local, remote: remote.metadata)
            let mergedData = try encoder.encode(merged)
            let remoteData = try encoder.encode(remote.metadata)
            let localData = try encoder.encode(local)

            if merged != local {
                merged.snapshot.apply(to: entry)
                summary.mergedCount += 1
                summary.downloadedBytes += Int64(mergedData.count)
            }
            persist(merged, on: entry)

            if mergedData != remoteData {
                uploads.append(RemoteMetadataRecord(entryID: entry.id, metadata: merged))
                setState(.pendingUpload, for: entry)
            } else {
                setState(.synced, for: entry)
                if localData != remoteData {
                    summary.downloadedCount += 1
                }
            }
        }

        // Entries awaiting remote deletion must not be resurrected from the cloud.
        let pendingDeletionIDs = PendingSyncDeletionStore.pendingEntryIDs()
        for remote in remoteByID.values
        where localByID[remote.entryID] == nil && !pendingDeletionIDs.contains(remote.entryID) {
            let entry = PhotoEntry(id: remote.entryID, day: remote.metadata.snapshot.day)
            remote.metadata.snapshot.apply(to: entry)
            persist(remote.metadata, on: entry)
            entry.metadataSyncState = .synced
            modelContext.insert(entry)
            localByID[entry.id] = entry
            summary.downloadedCount += 1
            summary.downloadedBytes += Int64((try encoder.encode(remote.metadata)).count)
        }

        if !uploads.isEmpty {
            for record in uploads {
                localByID[record.entryID].map { setState(.uploading, for: $0) }
            }
            try? modelContext.save()

            do {
                try await remoteStore.upload(uploads)
                for record in uploads {
                    guard let entry = localByID[record.entryID] else { continue }
                    persist(record.metadata, on: entry)
                    setState(.synced, for: entry)
                    summary.uploadedCount += 1
                    summary.uploadedBytes += Int64((try encoder.encode(record.metadata)).count)
                }
            } catch {
                for record in uploads {
                    guard let entry = localByID[record.entryID] else { continue }
                    setState(.failed, for: entry, error: error.localizedDescription)
                    summary.failedCount += 1
                }
            }
        }

        try modelContext.save()
        return summary
    }

    func captureLocalChanges(for entry: PhotoEntry, at date: Date = .now) -> VersionedMetadata {
        let current = MetadataSnapshot(entry: entry)
        let baseline = decodeSnapshot(entry.metadataBaselineData)
        var versioned = decodeVersioned(entry.metadataVersionData)
            ?? VersionedMetadata(snapshot: current, versions: [:])

        for field in VersionedMetadata.fieldNames where baseline == nil || changed(
            field,
            from: baseline,
            to: current
        ) {
            versioned.versions[field] = MetadataFieldVersion(
                modifiedAt: date,
                deviceID: deviceID
            )
        }
        versioned.snapshot = current
        persist(versioned, on: entry)
        return versioned
    }

    func merge(local: VersionedMetadata, remote: VersionedMetadata) -> VersionedMetadata {
        var result = local
        for field in VersionedMetadata.fieldNames {
            let localVersion = local.versions[field]
            let remoteVersion = remote.versions[field]
            guard shouldUseRemote(local: localVersion, remote: remoteVersion) else { continue }
            copy(field, from: remote.snapshot, to: &result.snapshot)
            result.versions[field] = remoteVersion
        }
        return result
    }

    private func shouldUseRemote(
        local: MetadataFieldVersion?,
        remote: MetadataFieldVersion?
    ) -> Bool {
        guard let remote else { return false }
        guard let local else { return true }
        return local < remote
    }

    private func changed(
        _ field: String,
        from old: MetadataSnapshot?,
        to new: MetadataSnapshot
    ) -> Bool {
        guard let old else { return true }
        return switch field {
        case "day": old.day != new.day
        case "captureDate": old.captureDate != new.captureDate
        case "latitude": old.latitude != new.latitude
        case "longitude": old.longitude != new.longitude
        case "timezone": old.timezone != new.timezone
        case "countryCode": old.countryCode != new.countryCode
        case "countryName": old.countryName != new.countryName
        case "city": old.city != new.city
        case "caption": old.caption != new.caption
        default: false
        }
    }

    private func copy(
        _ field: String,
        from source: MetadataSnapshot,
        to destination: inout MetadataSnapshot
    ) {
        switch field {
        case "day": destination.day = source.day
        case "captureDate": destination.captureDate = source.captureDate
        case "latitude": destination.latitude = source.latitude
        case "longitude": destination.longitude = source.longitude
        case "timezone": destination.timezone = source.timezone
        case "countryCode": destination.countryCode = source.countryCode
        case "countryName": destination.countryName = source.countryName
        case "city": destination.city = source.city
        case "caption": destination.caption = source.caption
        default: break
        }
    }

    private func persist(_ metadata: VersionedMetadata, on entry: PhotoEntry) {
        entry.metadataVersionData = try? encoder.encode(metadata)
        entry.metadataBaselineData = try? encoder.encode(metadata.snapshot)
    }

    private func decodeVersioned(_ data: Data?) -> VersionedMetadata? {
        guard let data else { return nil }
        return try? decoder.decode(VersionedMetadata.self, from: data)
    }

    private func decodeSnapshot(_ data: Data?) -> MetadataSnapshot? {
        guard let data else { return nil }
        return try? decoder.decode(MetadataSnapshot.self, from: data)
    }

    private func setState(_ state: SyncState, for entry: PhotoEntry, error: String? = nil) {
        if !entry.transitionSyncState(for: .metadata, to: state, errorMessage: error) {
            entry.metadataSyncState = state
            entry.syncStateUpdatedAt = .now
            if state == .failed {
                entry.lastSyncErrorComponentRaw = SyncComponent.metadata.rawValue
                entry.lastSyncErrorMessage = error
            }
        }
    }
}

struct CloudKitMetadataStore: MetadataRemoteStore {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark"),
        zoneName: String = SyncEnvironment.zoneName("DaymarkMetadataV2")
    ) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func inventory() async throws -> [String: RemoteMetadataRecord] {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return [:]
        }

        var result: [String: RemoteMetadataRecord] = [:]
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let changes = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: ["payload"]
            )
            for modification in changes.modificationResultsByID.values {
                guard case .success(let value) = modification,
                      value.record.recordType == "DaymarkMetadata",
                      let data = value.record["payload"] as? Data,
                      let metadata = try? decoder.decode(VersionedMetadata.self, from: data) else {
                    continue
                }
                let id = value.record.recordID.recordName
                result[id] = RemoteMetadataRecord(entryID: id, metadata: metadata)
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return result
    }

    func upload(_ records: [RemoteMetadataRecord]) async throws {
        try await ensureZoneExists()
        for chunk in records.chunked(maximumCount: 200) {
            let cloudRecords = try chunk.map { item in
                let id = CKRecord.ID(recordName: item.entryID, zoneID: zoneID)
                let record = CKRecord(recordType: "DaymarkMetadata", recordID: id)
                record["payload"] = try encoder.encode(item.metadata) as CKRecordValue
                return record
            }
            try await withCheckedThrowingContinuation { continuation in
                let operation = CKModifyRecordsOperation(recordsToSave: cloudRecords)
                operation.savePolicy = .changedKeys
                operation.isAtomic = true
                operation.qualityOfService = .utility
                operation.modifyRecordsResultBlock = { result in
                    continuation.resume(with: result.map { _ in () })
                }
                database.add(operation)
            }
        }
    }

    func delete(entryIDs: [String]) async throws {
        guard !entryIDs.isEmpty else { return }
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return
        }

        for chunk in entryIDs.chunked(maximumCount: 200) {
            let recordIDs = chunk.map {
                CKRecord.ID(recordName: $0, zoneID: zoneID)
            }
            try await withCheckedThrowingContinuation { continuation in
                let operation = CKModifyRecordsOperation(recordIDsToDelete: recordIDs)
                operation.isAtomic = true
                operation.qualityOfService = .utility
                operation.modifyRecordsResultBlock = { result in
                    continuation.resume(with: result.map { _ in () })
                }
                database.add(operation)
            }
        }
    }

    private func ensureZoneExists() async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }
}

enum SyncDeviceIdentity {
    static var current: String {
        let key = "daymark.sync.device-id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
