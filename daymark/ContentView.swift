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
        .task(id: assetSyncKey) {
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
            await photoStore.backfillViewPhotos(for: entries, in: modelContext)
            do {
                try await SyncEngine().sync(
                    entries: entries,
                    in: modelContext,
                    includeOriginals: false
                )
            } catch {
                SyncEngineStatusStore.shared.finish(entries: entries, confirmed: false)
#if DEBUG
                print("DAYMARK_SYNC_ENGINE_ERROR \(error.localizedDescription)")
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
