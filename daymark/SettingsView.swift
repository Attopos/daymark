import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]

    @Binding var prefersDarkMode: Bool
    private let photoStore = PhotoStore()

    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingImportOptions = false
    @State private var exportItem: DaymarkBackupExportItem?
    @State private var pendingBackup: BackupContents?
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    appearanceCard
                    iCloudSyncCard
                    libraryCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SignInAvatarButton()
                }
            }
            .alert("Backup Error", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "Backup failed.")
            }
            .confirmationDialog(
                "Import Backup",
                isPresented: $showingImportOptions,
                titleVisibility: .visible
            ) {
                Button("Merge (keep existing photos)") {
                    performImport(mode: .merge)
                }
                Button("Overwrite (replace existing photos)") {
                    performImport(mode: .overwrite)
                }
                Button("Cancel", role: .cancel) {
                    pendingBackup = nil
                }
            } message: {
                if let backup = pendingBackup {
                    Text("Found \(backup.payload.entries.count) entries. Choose how to handle days that already have a photo.")
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                item: exportItem,
                contentTypes: [.zip],
                defaultFilename: defaultBackupFilename
            ) { result in
                switch result {
                case .success:
                    statusMessage = "Backup exported."
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                exportItem = nil
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.zip, .json]
            ) { result in
                do {
                    let url = try result.get()
                    pendingBackup = try photoStore.parseBackup(from: url)
                    showingImportOptions = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var appearanceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)

            Text("Theme")
                .font(.headline)

            Spacer()

            HStack(spacing: 8) {
                themeButton(systemName: "sun.max.fill", isSelected: !prefersDarkMode) {
                    prefersDarkMode = false
                }

                themeButton(systemName: "moon.stars.fill", isSelected: prefersDarkMode) {
                    prefersDarkMode = true
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }

    private var iCloudSyncCard: some View {
        NavigationLink {
            ICloudSyncDetailView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Sync")
                        .font(.headline)

                    if FileManager.default.ubiquityIdentityToken != nil {
                        Text("Photos sync across your devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Sign in to iCloud to enable sync")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)

                Text("Backup")
                    .font(.headline)

                Spacer(minLength: 0)

                Button("Export", action: prepareExport)
                    .buttonStyle(.borderedProminent)

                Button("Import") {
                    showingImporter = true
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)
            }

            if isImporting {
                ProgressView("Importing backup…")
                    .font(.footnote)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }

    private func themeButton(systemName: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(isSelected ? Color.primary.opacity(0.12) : Color.clear, in: Circle())
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var defaultBackupFilename: String {
        "daymark-backup-\(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func prepareExport() {
        do {
            exportItem = try photoStore.makeBackupExportItem(from: entries)
            showingExporter = true
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performImport(mode: BackupImportMode) {
        guard let backup = pendingBackup else { return }
        pendingBackup = nil
        isImporting = true
        statusMessage = nil

        Task {
            do {
                try await photoStore.importBackup(
                    from: backup,
                    mode: mode,
                    into: modelContext
                )
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
                return
            }

            do {
                let importedEntries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
                try await SyncEngine().sync(
                    entries: importedEntries,
                    in: modelContext,
                    includeOriginals: true,
                    originalLimits: .unlimited
                )
                if SyncEngineStatusStore.shared.snapshot.failures.isEmpty {
                    statusMessage = "Imported \(backup.payload.entries.count) entries and confirmed with iCloud."
                } else {
                    statusMessage = "Imported locally, but iCloud sync finished with failures. Keep the backup and retry Sync Now."
                }
            } catch {
                statusMessage = "Imported locally, but iCloud sync did not finish. Keep the backup and retry Sync Now."
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

#Preview {
    SettingsView(prefersDarkMode: .constant(false))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
