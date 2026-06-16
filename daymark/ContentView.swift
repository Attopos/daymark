import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppDataController.self) private var dataController
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false
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

    /// A cheap signature over the fields that warrant re-running sync/backfill.
    /// Order-independent (per-entry hashes are wrap-added) so it avoids the
    /// large string allocation and sort the old key did on every data change.
    private var assetSyncKey: Int {
        var combined = entries.count
        for entry in entries {
            var hasher = Hasher()
            hasher.combine(entry.id)
            hasher.combine(entry.originalContentHash)
            hasher.combine(entry.day)
            hasher.combine(entry.captureDate)
            hasher.combine(entry.latitude)
            hasher.combine(entry.longitude)
            hasher.combine(entry.timezone)
            hasher.combine(entry.countryCode)
            hasher.combine(entry.countryName)
            hasher.combine(entry.city)
            hasher.combine(entry.caption)
            combined = combined &+ hasher.finalize()
        }
        return combined
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(AppDataController(scope: .anonymous))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
