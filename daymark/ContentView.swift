import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false
    @Query private var entries: [PhotoEntry]
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
        .task(id: thumbnailSyncKey) {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-runMetadataSyncExperiment") {
                await MetadataSyncExperiment.run(
                    arguments: ProcessInfo.processInfo.arguments,
                    in: modelContext
                )
                return
            }
#endif
            await photoStore.migrateLegacyLibraryIfNeeded(in: modelContext)
            photoStore.backfillMetadata(for: entries, in: modelContext)
            photoStore.migrateEmbeddedThumbnails(for: entries, in: modelContext)
            do {
                let summary = try await ThumbnailPhotoSyncCoordinator().syncThumbnails(
                    entries: entries,
                    in: modelContext
                )
#if DEBUG
                print(
                    "DAYMARK_THUMBNAIL_SYNC_RESULT " +
                    "uploaded=\(summary.uploadedCount) " +
                    "downloaded=\(summary.downloadedCount) " +
                    "failed=\(summary.failedCount) " +
                    "bytes=\(summary.transferredBytes)"
                )
#endif
            } catch {
#if DEBUG
                print("DAYMARK_THUMBNAIL_SYNC_ERROR \(error.localizedDescription)")
#endif
            }
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

    private var thumbnailSyncKey: String {
        entries
            .map { "\($0.id):\($0.thumbnailContentHash ?? "")" }
            .sorted()
            .joined(separator: "|")
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
