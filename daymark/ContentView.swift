import SwiftData
import SwiftUI
import UIKit

enum DaymarkTab: String, CaseIterable, Identifiable {
    case calendar, maps, daily, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .maps: "Maps"
        case .daily: "Daily"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .maps: "map"
        case .daily: "rectangle.stack"
        case .settings: "gearshape"
        }
    }
}

/// Daymark's own tab bar: opaque paper under a one-point ink rule, with the
/// selected tab printed in reverse, as on an e-ink reader. No glass, no motion.
struct DaymarkTabBar: View {
    @Binding var selection: DaymarkTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DaymarkTab.allCases) { tab in
                let isSelected = tab == selection

                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                    }
                    .foregroundStyle(isSelected ? DaymarkPalette.paper : DaymarkPalette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: DaymarkRadius.tile, style: .continuous)
                                .fill(DaymarkPalette.ink)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("tab-\(tab.title)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, DaymarkSpacing.s)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(DaymarkPalette.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(DaymarkPalette.ink).frame(height: 1)
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppDataController.self) private var dataController
    @AppStorage("prefersDarkMode") private var prefersDarkMode = false
    @Query private var entries: [PhotoEntry]
    @State private var isRunningAssetSync = false
    @State private var selectedTab = DaymarkTab.calendar
    @State private var isKeyboardVisible = false
    private let photoStore = PhotoStore()

    var body: some View {
        // The system tab bar is glass, so it is hidden and Daymark draws its
        // own opaque bar underneath. TabView still keeps each tab's state.
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                Tab(DaymarkTab.calendar.title, systemImage: DaymarkTab.calendar.symbol, value: DaymarkTab.calendar) {
                    CalendarView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }

                Tab(DaymarkTab.maps.title, systemImage: DaymarkTab.maps.symbol, value: DaymarkTab.maps) {
                    MapView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }

                Tab(DaymarkTab.daily.title, systemImage: DaymarkTab.daily.symbol, value: DaymarkTab.daily) {
                    DeskCalendarView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }

                Tab(DaymarkTab.settings.title, systemImage: DaymarkTab.settings.symbol, value: DaymarkTab.settings) {
                    SettingsView(prefersDarkMode: $prefersDarkMode)
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
            }

            // Out of the way while typing, so it does not ride up on the keyboard.
            if !isKeyboardVisible {
                DaymarkTabBar(selection: $selectedTab)
            }
        }
        .background(DaymarkPalette.paper.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .tint(DaymarkPalette.accent)
        .buttonBorderShape(.capsule)
        .preferredColorScheme(prefersDarkMode ? .dark : .light)
        .task(id: assetSyncKey) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !isRunningAssetSync else { return }
            isRunningAssetSync = true
            defer { isRunningAssetSync = false }

            photoStore.purgeSentinelEntries(in: modelContext)
#if DEBUG
            // UI tests run against the empty Debug library; this gives the
            // export flow one real photo to work with.
            if ProcessInfo.processInfo.arguments.contains("-uiTestSeedPhoto"), entries.isEmpty {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                }
                if let data = image.jpegData(compressionQuality: 0.9) {
                    try? await photoStore.savePhotoData(data, for: .now, in: modelContext)
                }
            }
#endif
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
            await photoStore.compactLibraryIfNeeded(for: currentEntries, in: modelContext)
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
                SyncEngineStatusStore.shared.finish(entries: entries.filter(\.isLive), confirmed: false)
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
