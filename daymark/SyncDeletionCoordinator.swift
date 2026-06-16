import CloudKit
import Foundation

struct PendingSyncDeletion: Codable, Equatable {
    let entryID: String
    let deletedAt: Date
}

enum PendingSyncDeletionStore {
    private static let defaultsKey = "daymark.sync.pending-deletions.v1"

    static func all() -> [PendingSyncDeletion] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PendingSyncDeletion].self, from: data) else {
            return []
        }
        return decoded
    }

    static func pendingEntryIDs() -> Set<String> {
        Set(all().map(\.entryID))
    }

    static func add(entryID: String) {
        var pending = all()
        guard !pending.contains(where: { $0.entryID == entryID }) else { return }
        pending.append(PendingSyncDeletion(entryID: entryID, deletedAt: .now))
        persist(pending)
    }

    static func remove(entryIDs: some Collection<String>) {
        guard !entryIDs.isEmpty else { return }
        let removed = Set(entryIDs)
        persist(all().filter { !removed.contains($0.entryID) })
    }

    private static func persist(_ pending: [PendingSyncDeletion]) {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Propagates local entry deletions to every CloudKit zone so that
/// metadata sync does not resurrect deleted entries from the cloud.
struct SyncDeletionCoordinator {
    private let database: CKDatabase

    private static let zoneNames = [
        "DaymarkMetadataV2",
        "DaymarkThumbnailAssetsV1",
        "DaymarkViewAssetsV1",
        "DaymarkOriginalAssetsV1",
    ].map(SyncEnvironment.zoneName)

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark")) {
        database = container.privateCloudDatabase
    }

    /// Deletes all pending-deletion records from every zone. IDs are cleared
    /// from the pending store only once every zone confirms the deletion, so
    /// a failed attempt is retried on the next sync.
    func flush() async {
        let pending = PendingSyncDeletionStore.all()
        guard !pending.isEmpty else { return }

        var confirmedIDs = Set(pending.map(\.entryID))

        for zoneName in Self.zoneNames {
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
            for chunk in pending.chunked(maximumCount: 200) {
                let recordIDs = chunk.map { CKRecord.ID(recordName: $0.entryID, zoneID: zoneID) }
                do {
                    let (_, deleteResults) = try await database.modifyRecords(
                        saving: [],
                        deleting: recordIDs,
                        atomically: false
                    )
                    for (recordID, result) in deleteResults {
                        if case .failure(let error) = result, !Self.isAlreadyGone(error) {
                            confirmedIDs.remove(recordID.recordName)
                        }
                    }
                } catch let error as CKError where error.code == .zoneNotFound {
                    continue
                } catch {
#if DEBUG
                    print("DAYMARK_DELETION_SYNC_ERROR zone=\(zoneName) \(error.localizedDescription)")
#endif
                    return
                }
            }
        }

        PendingSyncDeletionStore.remove(entryIDs: confirmedIDs)
#if DEBUG
        print("DAYMARK_DELETION_SYNC_DONE removed=\(confirmedIDs.count)")
#endif
    }

    private static func isAlreadyGone(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem || ckError.code == .zoneNotFound
    }
}
