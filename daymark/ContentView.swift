import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab: Tab = .calendar

    var body: some View {
        TabView(selection: $selectedTab) {
            CalendarView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(Tab.calendar)

            PlaceholderView(title: "Maps")
                .tabItem {
                    Label("Maps", systemImage: "map")
                }
                .tag(Tab.maps)

            PlaceholderView(title: "Settings")
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
    }
}

private enum Tab {
    case calendar
    case maps
    case settings
}

private struct PlaceholderView: View {
    let title: String

    var body: some View {
        NavigationStack {
            Color(.systemBackground)
                .ignoresSafeArea()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
