import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]

    @Binding var prefersDarkMode: Bool
    private let photoStore = PhotoStore()

    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("reminderHour") private var reminderHour = 20
    @AppStorage("reminderMinute") private var reminderMinute = 0

    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var showingImportOptions = false
    @State private var exportItem: DaymarkBackupExportItem?
    @State private var pendingBackup: BackupContents?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    appearanceCard
                    reminderCard
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

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)

                Text("Daily Reminder")
                    .font(.headline)

                Spacer(minLength: 0)

                Toggle("", isOn: $reminderEnabled)
                    .labelsHidden()
            }

            if reminderEnabled {
                DatePicker(
                    "Reminder time",
                    selection: reminderTimeBinding,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)
                .font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .onChange(of: reminderEnabled) { _, enabled in
            Task {
                if enabled {
                    let granted = await NotificationManager.requestAuthorization()
                    if granted {
                        await NotificationManager.scheduleDailyReminder(at: reminderHour, minute: reminderMinute)
                    } else {
                        reminderEnabled = false
                    }
                } else {
                    NotificationManager.cancelDailyReminder()
                }
            }
        }
        .onChange(of: reminderHour) { _, _ in
            guard reminderEnabled else { return }
            Task { await NotificationManager.scheduleDailyReminder(at: reminderHour, minute: reminderMinute) }
        }
        .onChange(of: reminderMinute) { _, _ in
            guard reminderEnabled else { return }
            Task { await NotificationManager.scheduleDailyReminder(at: reminderHour, minute: reminderMinute) }
        }
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = reminderHour
                components.minute = reminderMinute
                return Calendar.current.date(from: components) ?? .now
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                reminderHour = components.hour ?? 20
                reminderMinute = components.minute ?? 0
            }
        )
    }

    private var iCloudSyncCard: some View {
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

            Image(systemName: FileManager.default.ubiquityIdentityToken != nil ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(FileManager.default.ubiquityIdentityToken != nil ? .green : .secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
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
        do {
            try photoStore.importBackup(from: backup, mode: mode, into: modelContext)
            statusMessage = "Imported \(backup.payload.entries.count) entries."
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingBackup = nil
    }
}

#Preview {
    SettingsView(prefersDarkMode: .constant(false))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
