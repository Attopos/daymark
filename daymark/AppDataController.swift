import Foundation
import Observation
import SwiftData

/// The data partition currently in use. Each scope is backed by a distinct
/// on-disk store so that signed-in (iCloud-synced) data and anonymous data are
/// never visible to each other.
enum DataScope: Equatable {
    /// Signed in with an Apple account: the canonical store with CloudKit sync.
    case signedIn
    /// No account: a separate, local-only store that starts empty.
    case anonymous
}

/// Owns the active `ModelContainer` and rebuilds it when the identity scope
/// changes (sign in / sign out), so the visible data set follows the account.
@MainActor
@Observable
final class AppDataController {
    private(set) var scope: DataScope
    private(set) var container: ModelContainer

    init(scope: DataScope) {
        self.scope = scope
        self.container = Self.makeContainer(for: scope)
    }

    /// CloudKit sync only runs for the signed-in scope; the anonymous store is
    /// strictly local.
    var isCloudSyncEnabled: Bool {
        scope == .signedIn && LegacySyncMigration.usesSwiftDataMirroring
    }

    /// Swaps the container to a new scope. No-op if the scope is unchanged.
    func update(scope newScope: DataScope) {
        guard newScope != scope else { return }
        scope = newScope
        container = Self.makeContainer(for: newScope)
    }

    static func makeContainer(for scope: DataScope) -> ModelContainer {
        let schema = Schema([PhotoEntry.self])

        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase =
            (scope == .signedIn && LegacySyncMigration.usesSwiftDataMirroring)
                ? .private("iCloud.com.shizhengcao.Daymark")
                : .none

        func makeConfiguration(cloudKit: ModelConfiguration.CloudKitDatabase) -> ModelConfiguration {
            if let url = storeURL(for: scope) {
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: cloudKit)
            } else {
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: cloudKit)
            }
        }

        do {
            UserDefaults.standard.set(false, forKey: "cloudKitFallbackToLocal")
            return try ModelContainer(
                for: schema,
                configurations: [makeConfiguration(cloudKit: cloudKitDatabase)]
            )
        } catch {
            print("CloudKit ModelContainer failed, falling back to local storage: \(error)")
            UserDefaults.standard.set(true, forKey: "cloudKitFallbackToLocal")
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [makeConfiguration(cloudKit: .none)]
                )
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }

    private static func storeURL(for scope: DataScope) -> URL? {
        let url: URL? = switch scope {
        case .signedIn:
            // Canonical synced store: the existing default location in
            // Production (nil → SwiftData default), or the dedicated Debug store.
            SyncEnvironment.debugStoreURL
        case .anonymous:
            SyncEnvironment.anonymousStoreURL
        }

        // Unlike SwiftData's default store location, an explicit store URL does
        // not auto-create its parent directory. Application Support may not exist
        // yet on first launch, so create it or the container fails to open.
        if let url {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        return url
    }
}
