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
            Section("Status") {
                LabeledContent("iCloud") {
                    Text(icloudLabel)
                        .foregroundStyle(snapshot.iCloudAvailable ? Color.primary : Color.red)
                }
                LabeledContent("State") {
                    HStack(spacing: 7) {
                        if snapshot.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(snapshot.phase)
                            .foregroundStyle(stateColor)
                    }
                }
                LabeledContent("Last Confirmed") {
                    if let date = snapshot.lastConfirmedAt {
                        Text(date.formatted(.dateTime.month().day().hour().minute().second()))
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Pending") {
                byteRow(
                    title: "Upload",
                    count: snapshot.pendingUploadCount,
                    bytes: snapshot.pendingUploadBytes,
                    color: .orange
                )
                byteRow(
                    title: "Download",
                    count: snapshot.pendingDownloadCount,
                    bytes: snapshot.pendingDownloadBytes,
                    color: .blue
                )
            }

            Section("This Run") {
                LabeledContent("Uploaded") {
                    Text(formatted(snapshot.uploadedBytes))
                }
                LabeledContent("Downloaded") {
                    Text(formatted(snapshot.downloadedBytes))
                }
            }

            if !snapshot.failures.isEmpty {
                Section("Failures") {
                    ForEach(snapshot.failures) { failure in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(failure.component.label)
                                .font(.subheadline.weight(.medium))
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if !snapshot.conflicts.isEmpty {
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
        }
        .navigationTitle("iCloud Sync")
        .task {
            await SyncEngine().refresh(entries: entries)
        }
        .sheet(item: $selectedConflict) { conflict in
            conflictSheet(conflict)
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

    private var stateColor: Color {
        if !snapshot.failures.isEmpty || !snapshot.conflicts.isEmpty { return .red }
        return snapshot.isRunning ? .blue : .green
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
