import SwiftUI
import SwiftData

@main
struct DaymarkApp: App {
    @State private var authManager = AuthManager()
    @State private var locationLocalizer = LocationLocalizer()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PhotoEntry.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
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
