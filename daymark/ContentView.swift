import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false

    var body: some View {
        TabView {
            Tab("Calendar", systemImage: "calendar") {
                CalendarView()
            }

            Tab("Maps", systemImage: "map") {
                MapView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(prefersDarkMode: $prefersDarkMode)
            }
        }
        .preferredColorScheme(prefersDarkMode ? .dark : nil)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
