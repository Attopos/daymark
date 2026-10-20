import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppDataController.self) private var dataController
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
    @State private var isPreparingBackup = false
    @State private var completedPhotos = 0
    @State private var totalPhotos = 0
    @State private var progressMessage = ""
    @State private var backupTask: Task<Void, Never>?
    @AppStorage("lastCompleteBackupExport.signedIn") private var signedInExportTimestamp = 0.0
    @AppStorage("lastCompleteBackupExport.anonymous") private var anonymousExportTimestamp = 0.0

    private var isBusy: Bool { isImporting || isPreparingBackup }
    private var lastExportTimestamp: Double {
        get { dataController.scope == .signedIn ? signedInExportTimestamp : anonymousExportTimestamp }
        nonmutating set {
            if dataController.scope == .signedIn { signedInExportTimestamp = newValue }
            else { anonymousExportTimestamp = newValue }
        }
    }

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
            .daymarkScreen()
            .daymarkNavigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SignInAvatarButton()
                }
            }
            .onDisappear {
                backupTask?.cancel()
                pendingBackup?.cleanUp()
                pendingBackup = nil
            }
            .onChange(of: showingImportOptions) { _, showing in
                if !showing {
                    pendingBackup?.cleanUp()
                    pendingBackup = nil
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
                    pendingBackup?.cleanUp()
                    pendingBackup = nil
                }
            } message: {
                if let backup = pendingBackup {
                    Text(importPreview(for: backup))
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
                    lastExportTimestamp = Date.now.timeIntervalSince1970
                    statusMessage = "Complete backup saved. If you chose Google Drive, check Drive for upload completion."
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                exportItem?.cleanUp()
                exportItem = nil
            } onCancellation: {
                exportItem?.cleanUp()
                exportItem = nil
                statusMessage = "Export cancelled. Your photos are unchanged."
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.zip, .json]
            ) { result in
                switch result {
                case .success(let url): prepareImport(from: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var appearanceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(DaymarkPalette.accent.opacity(0.08), in: Circle())
                .foregroundStyle(DaymarkPalette.accent)

            Text("Theme")
                .font(DaymarkTypography.entryTitle)

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
        .daymarkSurface(cornerRadius: 24)
    }

    private var iCloudSyncCard: some View {
        NavigationLink {
            ICloudSyncDetailView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(DaymarkPalette.accent.opacity(0.08), in: Circle())
                    .foregroundStyle(DaymarkPalette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Sync")
                        .font(DaymarkTypography.entryTitle)

                    if FileManager.default.ubiquityIdentityToken != nil {
                        Text("Photos sync across your devices")
                            .font(DaymarkTypography.metadata)
                            .foregroundStyle(DaymarkPalette.secondaryInk)
                    } else {
                        Text("Sign in to iCloud to enable sync")
                            .font(DaymarkTypography.metadata)
                            .foregroundStyle(DaymarkPalette.secondaryInk)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DaymarkPalette.secondaryInk.opacity(0.65))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .daymarkSurface(cornerRadius: 24)
        }
        .buttonStyle(.plain)
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(DaymarkPalette.accent.opacity(0.08), in: Circle())
                    .foregroundStyle(DaymarkPalette.accent)

                Text("Backup")
                    .font(DaymarkTypography.entryTitle)

                Spacer(minLength: 0)

                Button("Export", action: prepareExport)
                    .buttonStyle(DaymarkPrimaryButtonStyle())
                    .disabled(isBusy || entries.isEmpty)

                Button("Import") {
                    showingImporter = true
                }
                .buttonStyle(DaymarkSecondaryButtonStyle())
                .disabled(isBusy)
            }

            if isBusy {
                VStack(alignment: .leading, spacing: 8) {
                    if totalPhotos > 0 {
                        ProgressView(value: Double(completedPhotos), total: Double(totalPhotos))
                    } else {
                        ProgressView()
                    }
                    HStack {
                        Text(progressMessage).font(.footnote)
                        Spacer()
                        Button("Cancel") { backupTask?.cancel() }
                            .font(.footnote)
                    }
                }
            }

            Text("Export includes original photos, dates, locations and captions. Choose Google Drive in Files to keep an independent copy.")
                .font(.footnote)
                .foregroundStyle(DaymarkPalette.secondaryInk)

            if lastExportTimestamp > 0 {
                Text("Last complete export: \(Date(timeIntervalSince1970: lastExportTimestamp).formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(DaymarkPalette.secondaryInk)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(DaymarkPalette.secondaryInk)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .daymarkSurface(cornerRadius: 24)
    }

    private func themeButton(systemName: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(isSelected ? DaymarkPalette.accent.opacity(0.10) : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(isSelected ? DaymarkPalette.accent.opacity(0.24) : DaymarkPalette.rule, lineWidth: 0.75))
                .foregroundStyle(isSelected ? DaymarkPalette.accent : DaymarkPalette.secondaryInk)
        }
        .buttonStyle(.plain)
    }

    private var defaultBackupFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "daymark-backup-\(formatter.string(from: .now))"
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func prepareExport() {
        guard !isBusy else { return }
        isPreparingBackup = true
        statusMessage = nil
        totalPhotos = entries.count
        completedPhotos = 0
        progressMessage = "Checking existing photos…"
        let snapshot = entries
        let canDownload = dataController.isCloudSyncEnabled
        backupTask = Task {
            defer { isPreparingBackup = false; backupTask = nil }
            do {
                exportItem = try await photoStore.makeBackupExportItem(
                    from: snapshot, in: modelContext, allowCloudDownload: canDownload
                ) { completed, total, message in
                    completedPhotos = completed
                    totalPhotos = total
                    progressMessage = message
                }
                try Task.checkCancellation()
                showingExporter = true
            } catch is CancellationError {
                exportItem?.cleanUp()
                exportItem = nil
                statusMessage = "Export cancelled. Your photos are unchanged."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareImport(from url: URL) {
        guard !isBusy else { return }
        isImporting = true
        totalPhotos = 0
        statusMessage = nil
        progressMessage = "Reading and verifying backup…"
        backupTask = Task {
            defer { isImporting = false; backupTask = nil }
            let reader = Task.detached(priority: .userInitiated) { try BackupArchiveReader.read(from: url) }
            do {
                let contents = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: { reader.cancel() }
                if Task.isCancelled { contents.cleanUp(); throw CancellationError() }
                pendingBackup = contents
                showingImportOptions = true
            } catch is CancellationError {
                statusMessage = "Import cancelled. Your photos are unchanged."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func importPreview(for backup: BackupContents) -> String {
        let days = backup.payload.entries.compactMap { try? BackupCalendar.restoredDay($0) }.sorted()
        let existingDays = Set(entries.map { Calendar.current.startOfDay(for: $0.day) })
        let conflicts = days.filter { existingDays.contains($0) }.count
        let range: String
        if let first = days.first, let last = days.last {
            range = "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)). "
        } else { range = "" }
        return "\(backup.payload.entries.count) photos verified. " + range +
            "\(conflicts) days already have a photo. Merge skips these days; Overwrite replaces only those days."
    }

    private func performImport(mode: BackupImportMode) {
        guard let backup = pendingBackup, !isBusy else { return }
        pendingBackup = nil
        isImporting = true
        statusMessage = nil
        totalPhotos = backup.payload.entries.count
        completedPhotos = 0
        progressMessage = "Preparing photos for restore…"
        backupTask = Task {
            defer { backup.cleanUp(); isImporting = false; backupTask = nil }
            do {
                let summary = try await photoStore.importBackup(from: backup, mode: mode, into: modelContext) { completed, total in
                    completedPhotos = completed
                    totalPhotos = total
                    progressMessage = "Preparing \(completed) of \(total) photos…"
                }
                statusMessage = "Restored \(summary.imported) photos locally; kept \(summary.skipped) existing days."
                // Local restore is complete. The existing sync engine handles
                // optional iCloud sync independently when it next runs.
            } catch is CancellationError {
                statusMessage = "Import cancelled. Your photos are unchanged."
            } catch { errorMessage = error.localizedDescription }
        }
    }

}

#Preview {
    SettingsView(prefersDarkMode: .constant(false))
        .environment(AuthManager())
        .environment(AppDataController(scope: .anonymous))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
