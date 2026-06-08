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
        .task {
            await photoStore.migrateLegacyLibraryIfNeeded(in: modelContext)
            let descriptor = FetchDescriptor<PhotoEntry>()
            if let entries = try? modelContext.fetch(descriptor) {
                photoStore.backfillMetadata(for: entries, in: modelContext)
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-runOriginalSyncExperiment") {
                    await runOriginalSyncExperiment(entries: entries)
                }
                if ProcessInfo.processInfo.arguments.contains("-runOriginalInventoryExperiment") {
                    await runOriginalInventoryExperiment()
                }
#endif
            }
        }
    }

#if DEBUG
    private func runOriginalSyncExperiment(entries: [PhotoEntry]) async {
        do {
            let summary = try await OriginalPhotoSyncCoordinator().syncOriginals(
                entries: entries,
                in: modelContext,
                limits: OriginalPhotoSyncLimits(
                    maximumTransferCount: 1,
                    maximumTransferredBytes: 100 * 1_024 * 1_024
                )
            )
            print(
                "DAYMARK_SYNC_EXPERIMENT_RESULT " +
                "uploaded=\(summary.uploadedCount) " +
                "downloaded=\(summary.downloadedCount) " +
                "conflicts=\(summary.conflictCount) " +
                "failed=\(summary.failedCount) " +
                "deferred=\(summary.deferredCount) " +
                "bytes=\(summary.transferredBytes)"
            )
        } catch {
            print("DAYMARK_SYNC_EXPERIMENT_ERROR \(error.localizedDescription)")
        }
    }

    private func runOriginalInventoryExperiment() async {
        do {
            let inventory = try await CloudKitOriginalPhotoStore().inventory()
            print("DAYMARK_INVENTORY_EXPERIMENT_RESULT records=\(inventory.count)")
        } catch {
            print("DAYMARK_INVENTORY_EXPERIMENT_ERROR \(error.localizedDescription)")
        }
    }
#endif
}

#Preview {
    ContentView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
