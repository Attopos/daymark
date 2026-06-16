import SwiftUI
import SwiftData

@main
struct DaymarkApp: App {
    @State private var authManager: AuthManager
    @State private var dataController: AppDataController
    @State private var locationLocalizer = LocationLocalizer()
    @AppStorage(AuthManager.hasCompletedWelcomeKey) private var hasCompletedWelcome = false
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false

    init() {
        let authManager = AuthManager()
        _authManager = State(initialValue: authManager)
        _dataController = State(
            initialValue: AppDataController(scope: authManager.isSignedIn ? .signedIn : .anonymous)
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedWelcome {
                    ContentView()
                        .id(dataController.scope)
                        .modelContainer(dataController.container)
                } else {
                    WelcomeView {
                        hasCompletedWelcome = true
                    }
                }
            }
                .preferredColorScheme(prefersDarkMode ? .dark : .light)
                .environment(authManager)
                .environment(dataController)
                .environment(locationLocalizer)
                .task {
                    await authManager.checkCredentialState()
                }
                .onChange(of: authManager.isSignedIn) { _, signedIn in
                    dataController.update(scope: signedIn ? .signedIn : .anonymous)
                }
                .modelContainer(dataController.container)
        }
    }
}
