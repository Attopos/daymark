import SwiftUI
import SwiftData

@main
struct DaymarkApp: App {
    @State private var authManager = AuthManager()
    @State private var locationLocalizer = LocationLocalizer()

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PhotoEntry.self,
        ])
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase =
            LegacySyncMigration.usesSwiftDataMirroring
                ? .private("iCloud.com.shizhengcao.Daymark")
                : .none

        // Debug builds use a dedicated store file so development data never
        // mixes with the production store when both builds run on one device.
        let config: ModelConfiguration
        if let debugStoreURL = SyncEnvironment.debugStoreURL {
            config = ModelConfiguration(
                schema: schema,
                url: debugStoreURL,
                cloudKitDatabase: cloudKitDatabase
            )
        } else {
            config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: cloudKitDatabase
            )
        }

        do {
            UserDefaults.standard.set(false, forKey: "cloudKitFallbackToLocal")
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("CloudKit ModelContainer failed, falling back to local storage: \(error)")
            UserDefaults.standard.set(true, forKey: "cloudKitFallbackToLocal")
            let localConfig: ModelConfiguration
            if let debugStoreURL = SyncEnvironment.debugStoreURL {
                localConfig = ModelConfiguration(schema: schema, url: debugStoreURL, cloudKitDatabase: .none)
            } else {
                localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            }
            do {
                return try ModelContainer(for: schema, configurations: [localConfig])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(locationLocalizer)
                .task {
                    await authManager.checkCredentialState()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
