import CloudKit
import CoreData
import Network
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

struct ICloudSyncDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("iCloudSyncEnabled") private var syncEnabled = true
    @AppStorage("lastSuccessfulSyncTimestamp") private var lastSuccessfulSyncTimestamp: Double = 0
    @AppStorage("cloudKitFallbackToLocal") private var fellBackToLocal = false

    @State private var networkNormal = false
    @State private var iCloudConnected = false
    @State private var syncStatus = "Checking..."
    @State private var syncMessage: String?
    @State private var isSyncing = false
    @State private var syncProgress: Double = 0
    @State private var syncDirection: SyncDirection?
    @State private var expectedTotal: Int = 0
    @State private var progressTask: Task<Void, Never>?

    private enum SyncDirection {
        case push, pull
        var label: String { self == .push ? "Pushing" : "Pulling" }
        var icon: String { self == .push ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
        var tint: Color { self == .push ? .blue : .green }
    }

    private let ckContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark")
    private let syncZoneID = CKRecordZone.ID(
        zoneName: "com.apple.coredata.cloudkit.zone",
        ownerName: CKCurrentUserDefaultName
    )

    private var lastSyncDate: Date? {
        lastSuccessfulSyncTimestamp > 0 ? Date(timeIntervalSince1970: lastSuccessfulSyncTimestamp) : nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Sync", isOn: $syncEnabled)
            }

            if syncEnabled {
                if fellBackToLocal {
                    Section {
                        Label("CloudKit failed to initialize. Sync is running in local-only mode. Restart the app to retry.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    LabeledContent("Network") {
                        Text(networkNormal ? "Normal" : "Unavailable")
                            .foregroundStyle(networkNormal ? Color.primary : Color.red)
                    }

                    LabeledContent("iCloud") {
                        Text(iCloudConnected ? "Connected" : "Not Signed In")
                            .foregroundStyle(iCloudConnected ? Color.primary : Color.red)
                    }

                    LabeledContent("Syncing Status") {
                        Text(syncStatus)
                            .foregroundStyle(syncStatus == "Success" ? .green : .secondary)
                    }

                    LabeledContent("Recent Sync Date") {
                        if let lastSyncDate {
                            Text(lastSyncDate.formatted(.dateTime.year().month().day().hour().minute().second()))
                        } else {
                            Text("—")
                        }
                    }
                }

                if isSyncing, let direction = syncDirection {
                    Section {
                        VStack(spacing: 10) {
                            HStack {
                                Image(systemName: direction.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(direction.tint)
                                Text(direction.label)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int(syncProgress * 100))%")
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(direction.tint)
                            }
                            ProgressView(value: syncProgress)
                                .tint(direction.tint)
                        }
                    } footer: {
                        if let syncMessage {
                            Text(syncMessage)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await manualSync() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            if isSyncing && syncDirection == nil {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing || fellBackToLocal || !iCloudConnected)
                } footer: {
                    if !isSyncing, let syncMessage {
                        Text(syncMessage)
                    }
                }
            }
        }
        .navigationTitle("iCloud Sync")
        .task { await checkStatuses() }
        .task { await observeSyncEvents() }
    }

    private func manualSync() async {
        isSyncing = true
        syncMessage = nil
        syncDirection = nil
        syncProgress = 0
        syncStatus = "Verifying access..."

        // Step 1: Test actual CloudKit write access
        do {
            try await verifyCloudKitWriteAccess()
        } catch {
            let detail = describeCloudKitError(error)
            syncStatus = "Error"
            syncMessage = detail
            isSyncing = false
            return
        }

        syncStatus = "Checking iCloud..."

        let descriptor = FetchDescriptor<PhotoEntry>()
        let localCount = (try? modelContext.fetch(descriptor))?.count ?? 0

        do {
            let cloudCount = try await fetchCloudRecordCount()

            if cloudCount == 0 && localCount == 0 {
                syncStatus = "No Data"
                syncMessage = "No photos found locally or in iCloud."
                isSyncing = false
            } else if cloudCount == 0 {
                startSync(direction: .push, expected: localCount, message: "No iCloud data found. Uploading \(localCount) entries...")
            } else if localCount == 0 {
                startSync(direction: .pull, expected: cloudCount, message: "Found \(cloudCount) entries in iCloud. Downloading...")
            } else if localCount < cloudCount {
                startSync(direction: .pull, expected: cloudCount, message: "iCloud has \(cloudCount) entries, local has \(localCount). Pulling...")
            } else if localCount > cloudCount {
                startSync(direction: .push, expected: localCount, message: "Local has \(localCount) entries, iCloud has \(cloudCount). Pushing...")
            } else {
                syncStatus = "Success"
                syncMessage = "\(localCount) entries in sync across devices."
                lastSuccessfulSyncTimestamp = Date.now.timeIntervalSince1970
                isSyncing = false
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .serverRejectedRequest || error.code == .unknownItem {
            if localCount > 0 {
                startSync(direction: .push, expected: localCount, message: "No iCloud data found. Uploading \(localCount) entries...")
            } else {
                syncStatus = "No Data"
                syncMessage = "No photos found locally or in iCloud."
                isSyncing = false
            }
        } catch {
            syncStatus = "Error"
            syncMessage = describeCloudKitError(error)
            isSyncing = false
        }
    }

    private func verifyCloudKitWriteAccess() async throws {
        let database = ckContainer.privateCloudDatabase
        let zone = CKRecordZone(zoneID: syncZoneID)
        _ = try await database.save(zone)
    }

    private func describeCloudKitError(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }
        switch ckError.code {
        case .notAuthenticated:
            return "Not signed into iCloud. Go to Settings > Apple Account and sign in."
        case .permissionFailure:
            return "iCloud permission denied. Go to Settings > Apple Account > iCloud > Apps Using iCloud and enable Daymark."
        case .missingEntitlement:
            return "App is missing CloudKit entitlement. Rebuild from Xcode with iCloud capability enabled."
        case .badContainer:
            return "CloudKit container not found. Verify the container exists in Apple Developer portal."
        case .quotaExceeded:
            return "iCloud storage is full. Free up space in Settings > Apple Account > iCloud > Manage Storage."
        case .networkUnavailable, .networkFailure:
            return "Network unavailable. Check your internet connection."
        case .serverRejectedRequest:
            return "CloudKit rejected the request (error 15). The CloudKit schema may need to be deployed in the CloudKit Dashboard."
        case .requestRateLimited:
            return "Rate limited by iCloud. Try again in a few minutes."
        default:
            return "CloudKit error \(ckError.code.rawValue): \(ckError.localizedDescription)"
        }
    }

    private func startSync(direction: SyncDirection, expected: Int, message: String) {
        syncDirection = direction
        expectedTotal = expected
        syncProgress = 0
        syncStatus = direction.label + "..."
        syncMessage = message
        try? modelContext.save()
        progressTask?.cancel()
        progressTask = Task { await monitorProgress() }
    }

    private func monitorProgress() async {
        while isSyncing && !Task.isCancelled {
            try? await Task.sleep(for: syncDirection == .push ? .seconds(3) : .seconds(1))
            guard !Task.isCancelled else { break }

            var current = 0
            switch syncDirection {
            case .pull:
                let descriptor = FetchDescriptor<PhotoEntry>()
                current = (try? modelContext.fetch(descriptor))?.count ?? 0
            case .push:
                current = (try? await fetchCloudRecordCount()) ?? 0
            case .none:
                break
            }

            guard expectedTotal > 0 else { continue }
            let progress = min(Double(current) / Double(expectedTotal), 0.99)
            withAnimation(.linear(duration: 0.3)) {
                syncProgress = progress
            }
        }
    }

    private func finishSync(success: Bool, date: Date?, error: Error?) {
        progressTask?.cancel()
        progressTask = nil
        withAnimation(.linear(duration: 0.3)) {
            syncProgress = success ? 1.0 : syncProgress
        }
        if success {
            syncStatus = "Success"
            syncMessage = "Sync completed."
            if let date { lastSuccessfulSyncTimestamp = date.timeIntervalSince1970 }
        } else {
            syncStatus = "Error"
            syncMessage = error?.localizedDescription ?? "Sync failed."
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            isSyncing = false
            syncDirection = nil
        }
    }

    private func fetchCloudRecordCount() async throws -> Int {
        let database = ckContainer.privateCloudDatabase
        _ = try await database.recordZone(for: syncZoneID)

        let query = CKQuery(
            recordType: "CD_PhotoEntry",
            predicate: NSPredicate(format: "CD_day != NIL")
        )

        var count = 0
        let (firstBatch, firstCursor) = try await database.records(
            matching: query,
            inZoneWith: syncZoneID,
            desiredKeys: []
        )
        count += firstBatch.count

        var cursor = firstCursor
        while let current = cursor {
            let (batch, next) = try await database.records(
                continuingMatchFrom: current,
                desiredKeys: []
            )
            count += batch.count
            cursor = next
        }

        return count
    }

    private func checkStatuses() async {
        let monitor = NWPathMonitor()
        networkNormal = await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.resume(returning: path.status == .satisfied)
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "net-check"))
        }

        iCloudConnected = FileManager.default.ubiquityIdentityToken != nil

        if fellBackToLocal {
            syncStatus = "Local Only"
            return
        }

        do {
            let status = try await ckContainer.accountStatus()
            if status == .available {
                syncStatus = "Success"
                lastSuccessfulSyncTimestamp = Date.now.timeIntervalSince1970
            } else {
                syncStatus = "Unavailable"
            }
        } catch {
            syncStatus = "Error"
        }
    }

    private func observeSyncEvents() async {
        guard !fellBackToLocal else { return }
        let notifications = NotificationCenter.default.notifications(
            named: NSPersistentCloudKitContainer.eventChangedNotification
        )
        for await notification in notifications {
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { continue }
            if let endDate = event.endDate {
                finishSync(success: event.succeeded, date: endDate, error: event.error)
            }
        }
    }
}

#Preview {
    SettingsView(prefersDarkMode: .constant(false))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
