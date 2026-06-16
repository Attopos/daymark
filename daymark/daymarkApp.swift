import SwiftUI
import SwiftData

@main
struct DaymarkApp: App {
    @State private var authManager: AuthManager
    @State private var dataController: AppDataController
    @State private var locationLocalizer = LocationLocalizer()

    init() {
        let authManager = AuthManager()
        _authManager = State(initialValue: authManager)
        _dataController = State(
            initialValue: AppDataController(scope: authManager.isSignedIn ? .signedIn : .anonymous)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
