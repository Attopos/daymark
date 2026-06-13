import SwiftData
import SwiftUI

struct ICloudSyncDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]
    @AppStorage("cloudKitFallbackToLocal") private var fellBackToLocal = false

    @State private var statusStore = SyncEngineStatusStore.shared
    @State private var selectedConflict: SyncConflictItem?
    @State private var selectedResolution: OriginalConflictResolution?
    @State private var message: String?

    private var snapshot: SyncStatusSnapshot { statusStore.snapshot }

    var body: some View {
        Form {
            heroSection

            Section {
                LabeledContent("iCloud Account") {
                    Text(icloudLabel)
                        .foregroundStyle(snapshot.iCloudAvailable && !fellBackToLocal ? Color.primary : Color.red)
                }
                LabeledContent("Last Synced") {
                    Text(lastSyncedLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if needsAttention {
                attentionSection
            }

            if !snapshot.conflicts.isEmpty {
                conflictsSection
            }

            Section {
                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if snapshot.isRunning {
                            ProgressView()
                        }
                    }
                }
                .disabled(snapshot.isRunning || fellBackToLocal)
            } footer: {
                if let message {
                    Text(message)
                }
            }

            diagnosticsSection
        }
        .navigationTitle("iCloud Sync")
        .task {
            await SyncEngine().refresh(entries: entries)
        }
        .sheet(item: $selectedConflict) { conflict in
            conflictSheet(conflict)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                ZStack {
                    if snapshot.isRunning {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: state.icon)
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(state.tint)
                    }
                }
                .frame(height: 44)

                Text(state.title)
                    .font(.title3.weight(.semibold))
                Text(state.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Needs Attention

    private var attentionSection: some View {
        Section {
            ForEach(snapshot.failures) { failure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.component.label)
                        .font(.subheadline.weight(.medium))
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if !snapshot.failures.isEmpty {
                Button {
                    Task { await syncNow() }
                } label: {
                    Label("Retry Failed Items", systemImage: "arrow.clockwise")
                }
                .disabled(snapshot.isRunning || fellBackToLocal)
            }
        } header: {
            Text("Needs Attention")
        } footer: {
            if !snapshot.conflicts.isEmpty {
                Text("\(snapshot.conflicts.count) photo \(snapshot.conflicts.count == 1 ? "conflict needs" : "conflicts need") your choice below.")
            }
        }
    }

    private var conflictsSection: some View {
        Section {
            ForEach(snapshot.conflicts) { conflict in
                Button {
                    selectedConflict = conflict
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conflict.day.formatted(.dateTime.year().month().day()))
                                .foregroundStyle(.primary)
                            Text(
                                conflict.remoteIsPreserved
                                    ? "Both versions preserved"
                                    : "Waiting to preserve iCloud version"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                conflict.remoteIsPreserved ? Color.secondary : Color.red
                            )
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Photo Conflicts")
        } footer: {
            Text("Daymark keeps both files until you choose a version.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("Diagnostics") {
                LabeledContent("Phase", value: snapshot.phase)
                byteRow(
                    title: "Pending Upload",
                    count: snapshot.pendingUploadCount,
                    bytes: snapshot.pendingUploadBytes,
                    color: .orange
                )
                byteRow(
                    title: "Pending Download",
                    count: snapshot.pendingDownloadCount,
                    bytes: snapshot.pendingDownloadBytes,
                    color: .blue
                )
                LabeledContent("Uploaded (this run)") {
                    Text(formatted(snapshot.uploadedBytes))
                }
                LabeledContent("Downloaded (this run)") {
                    Text(formatted(snapshot.downloadedBytes))
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func conflictSheet(_ conflict: SyncConflictItem) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    conflictVersion(
                        title: "This Device",
                        image: entry(for: conflict.entryID).flatMap(PhotoStore().image(for:)),
                        bytes: conflict.localBytes,
                        actionTitle: "Keep This Device",
                        action: { selectedResolution = .keptLocal }
                    )
                    conflictVersion(
                        title: "iCloud",
                        image: entry(for: conflict.entryID).flatMap(PhotoStore().conflictOriginalImage(for:)),
                        bytes: conflict.remoteBytes,
                        actionTitle: "Use iCloud",
                        action: { selectedResolution = .usedICloud }
                    )
                }
                .padding()
            }
            .navigationTitle("Choose Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { selectedConflict = nil }
                }
            }
            .confirmationDialog(
                resolutionTitle,
                isPresented: resolutionBinding,
                titleVisibility: .visible
            ) {
                Button(resolutionButtonTitle, role: .destructive) {
                    guard let resolution = selectedResolution else { return }
                    Task { await resolve(conflict, using: resolution) }
                }
                Button("Cancel", role: .cancel) {
                    selectedResolution = nil
                }
            } message: {
                Text("The unselected version remains preserved until the operation succeeds.")
            }
        }
    }

    private func conflictVersion(
        title: String,
        image: UIImage?,
        bytes: Int64,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(formatted(bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
                    .frame(minHeight: 180)
            }
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func byteRow(title: String, count: Int, bytes: Int64, color: Color) -> some View {
        LabeledContent(title) {
            Text("\(count) · \(formatted(bytes))")
                .foregroundStyle(count == 0 ? Color.primary : color)
        }
    }

    private func syncNow() async {
        message = nil
        do {
            try await SyncEngine().sync(
                entries: entries,
                in: modelContext,
                includeOriginals: true
            )
            message = statusStore.snapshot.failures.isEmpty
                ? "Confirmed with iCloud."
                : "Sync finished with failures."
        } catch {
            statusStore.finish(entries: entries, confirmed: false)
            message = error.localizedDescription
        }
    }

    private func resolve(
        _ conflict: SyncConflictItem,
        using resolution: OriginalConflictResolution
    ) async {
        guard let entry = entry(for: conflict.entryID) else { return }
        selectedResolution = nil
        do {
            switch resolution {
            case .keptLocal:
                try await OriginalPhotoConflictResolver().keepLocal(entry, in: modelContext)
            case .usedICloud:
                try await OriginalPhotoConflictResolver().useICloud(entry, in: modelContext)
            }
            selectedConflict = nil
            statusStore.refresh(entries: entries)
            message = "Conflict resolved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func entry(for id: String) -> PhotoEntry? {
        entries.first { $0.id == id }
    }

    private var icloudLabel: String {
        if fellBackToLocal { return "Local Only" }
        return snapshot.iCloudAvailable ? "Connected" : "Unavailable"
    }

    private var needsAttention: Bool {
        !snapshot.failures.isEmpty || !snapshot.conflicts.isEmpty
    }

    private var pendingCount: Int {
        snapshot.pendingUploadCount + snapshot.pendingDownloadCount
    }

    private var lastSyncedLabel: String {
        guard let date = snapshot.lastConfirmedAt else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private struct StateInfo {
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
    }

    private var state: StateInfo {
        if fellBackToLocal {
            return StateInfo(
                icon: "icloud.slash.fill",
                tint: .secondary,
                title: "Local Only",
                subtitle: "iCloud sync is off. Your photos stay on this device."
            )
        }
        if !snapshot.iCloudAvailable {
            return StateInfo(
                icon: "exclamationmark.icloud.fill",
                tint: .orange,
                title: "iCloud Unavailable",
                subtitle: "Sign in to iCloud in Settings to keep your photos backed up."
            )
        }
        if snapshot.isRunning {
            return StateInfo(
                icon: "arrow.triangle.2.circlepath.icloud.fill",
                tint: .blue,
                title: "Syncing…",
                subtitle: runningSubtitle
            )
        }
        if needsAttention {
            let failures = snapshot.failures.count
            let conflicts = snapshot.conflicts.count
            var parts: [String] = []
            if failures > 0 { parts.append("\(failures) \(failures == 1 ? "item" : "items") failed") }
            if conflicts > 0 { parts.append("\(conflicts) photo \(conflicts == 1 ? "conflict" : "conflicts")") }
            return StateInfo(
                icon: "exclamationmark.icloud.fill",
                tint: .red,
                title: "Needs Attention",
                subtitle: parts.joined(separator: " · ")
            )
        }
        if pendingCount > 0 {
            return StateInfo(
                icon: "icloud.and.arrow.up.fill",
                tint: .blue,
                title: "Waiting to Sync",
                subtitle: "\(pendingCount) \(pendingCount == 1 ? "item" : "items") waiting. Tap Sync Now to back them up."
            )
        }
        return StateInfo(
            icon: "checkmark.icloud.fill",
            tint: .green,
            title: "Up to Date",
            subtitle: snapshot.lastConfirmedAt == nil
                ? "Everything is backed up to iCloud."
                : "Last synced \(lastSyncedLabel)."
        )
    }

    private var runningSubtitle: String {
        if snapshot.pendingUploadCount > 0 {
            return "Uploading \(snapshot.pendingUploadCount) \(snapshot.pendingUploadCount == 1 ? "item" : "items")…"
        }
        if snapshot.pendingDownloadCount > 0 {
            return "Downloading \(snapshot.pendingDownloadCount) \(snapshot.pendingDownloadCount == 1 ? "item" : "items")…"
        }
        return "Checking for changes…"
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var resolutionBinding: Binding<Bool> {
        Binding(
            get: { selectedResolution != nil },
            set: { if !$0 { selectedResolution = nil } }
        )
    }

    private var resolutionTitle: String {
        selectedResolution == .keptLocal ? "Keep This Device?" : "Use iCloud?"
    }

    private var resolutionButtonTitle: String {
        selectedResolution == .keptLocal ? "Keep This Device" : "Use iCloud"
    }
}

private extension SyncComponent {
    var label: String {
        switch self {
        case .metadata: "Metadata"
        case .thumbnail: "Thumbnail"
        case .viewPhoto: "Viewing Photo"
        case .original: "Original Photo"
        }
    }
}
