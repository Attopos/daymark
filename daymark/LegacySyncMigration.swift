import Foundation

enum LegacySyncMigration {
    static let usesSwiftDataMirroring = true
    static let customMetadataDeletionReady = false

    enum Phase: String {
        case dualWriteMigration
        case readyForRemoval
    }

    private static let firstCompletedVersionKey = "daymark.legacy-sync.first-completed-version"

    static var phase: Phase {
        guard let firstVersion = UserDefaults.standard.string(
            forKey: firstCompletedVersionKey
        ) else {
            return .dualWriteMigration
        }
        return firstVersion == currentVersion ? .dualWriteMigration : .readyForRemoval
    }

    static func recordSuccessfulMigrationCycle() {
        guard UserDefaults.standard.string(forKey: firstCompletedVersionKey) == nil else {
            return
        }
        UserDefaults.standard.set(currentVersion, forKey: firstCompletedVersionKey)
    }

    static func mayRemoveLegacyStorage(entries: [PhotoEntry]) -> Bool {
        phase == .readyForRemoval &&
        customMetadataDeletionReady &&
        entries.allSatisfy { $0.imageData == nil && $0.thumbnailData == nil }
    }

    private static var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
    }
}
