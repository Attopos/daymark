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
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.shizhengcao.Daymark")
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("CloudKit ModelContainer failed, falling back to local storage: \(error.localizedDescription)")
            let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
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
