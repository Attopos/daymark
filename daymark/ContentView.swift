import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppDataController.self) private var dataController
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false
    @AppStorage(AuthManager.hasCompletedWelcomeKey) private var hasCompletedWelcome = false
    @Query private var entries: [PhotoEntry]
    @State private var isRunningAssetSync = false
    private let photoStore = PhotoStore()

    var body: some View {
        TabView {
            Tab("Calendar", systemImage: "calendar") {
                CalendarView()
            }

            Tab("Maps", systemImage: "map") {
                MapView()
            }

            Tab("Timeline", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                TimelineView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(prefersDarkMode: $prefersDarkMode)
            }
        }
        .preferredColorScheme(prefersDarkMode ? .dark : .light)
        .fullScreenCover(isPresented: showingWelcome) {
            WelcomeView {
                hasCompletedWelcome = true
            }
            .preferredColorScheme(prefersDarkMode ? .dark : .light)
        }
        .task(id: assetSyncKey) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !isRunningAssetSync else { return }
            isRunningAssetSync = true
            defer { isRunningAssetSync = false }

            photoStore.purgeSentinelEntries(in: modelContext)
            await photoStore.migrateLegacyLibraryIfNeeded(in: modelContext)
            photoStore.backfillMetadata(for: entries, in: modelContext)
            do {
                try photoStore.consolidateDuplicateDays(for: entries, in: modelContext)
            } catch {
#if DEBUG
                print("DAYMARK_DUPLICATE_CONSOLIDATION_ERROR \(error.localizedDescription)")
#endif
            }
            let currentEntries = (try? modelContext.fetch(FetchDescriptor<PhotoEntry>())) ?? entries
            photoStore.migrateEmbeddedThumbnails(for: currentEntries, in: modelContext)
            await photoStore.backfillViewPhotos(for: currentEntries, in: modelContext)

            // The anonymous scope is strictly local — never touch CloudKit.
            guard dataController.isCloudSyncEnabled else { return }
            do {
                try await SyncEngine().sync(
                    entries: currentEntries,
                    in: modelContext,
                    includeOriginals: false
                )
            } catch {
                SyncEngineStatusStore.shared.finish(entries: entries, confirmed: false)
#if DEBUG
                print("DAYMARK_SYNC_ENGINE_ERROR \(error.localizedDescription)")
#endif
            }
        }
    }

    private var showingWelcome: Binding<Bool> {
        Binding(
            get: { !hasCompletedWelcome },
            set: { if !$0 { hasCompletedWelcome = true } }
        )
    }

    private var assetSyncKey: String {
        entries
            .map {
                [
                    $0.id,
                    $0.originalContentHash ?? "",
                    $0.day.timeIntervalSince1970.description,
                    $0.captureDate?.timeIntervalSince1970.description ?? "",
                    $0.latitude?.description ?? "",
                    $0.longitude?.description ?? "",
                    $0.timezone ?? "",
                    $0.countryCode ?? "",
                    $0.countryName ?? "",
                    $0.city ?? "",
                    $0.caption ?? "",
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(AppDataController(scope: .anonymous))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
