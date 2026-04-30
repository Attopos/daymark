import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false
    private let photoStore = PhotoStore()

    var body: some View {
        TabView {
            Tab("Calendar", systemImage: "calendar") {
                CalendarView()
            }

            Tab("Search", systemImage: "magnifyingglass") {
                SearchView()
            }

            Tab("Maps", systemImage: "map") {
                MapView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(prefersDarkMode: $prefersDarkMode)
            }
        }
        .preferredColorScheme(prefersDarkMode ? .dark : nil)
        .task {
            await photoStore.migrateLegacyLibraryIfNeeded(in: modelContext)
            let descriptor = FetchDescriptor<PhotoEntry>()
            if let entries = try? modelContext.fetch(descriptor) {
                photoStore.backfillMetadata(for: entries, in: modelContext)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
