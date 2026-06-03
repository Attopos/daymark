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
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var syncActivities: [UUID: SyncActivity] = [:]
    @State private var localPhotoCount: Int = 0
    @State private var cloudPhotoCount: Int?
    @State private var pollingTask: Task<Void, Never>?
    @State private var cachedChangeToken: CKServerChangeToken?
    @State private var cachedCloudIDs: Set<CKRecord.ID> = []
    @State private var hasFullCloudSnapshot = false
    #if DEBUG
    @State private var isTestingCloudKit = false
    @State private var cloudKitTestResult: String?
    #endif

    private let ckContainer = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark")
    private let syncZoneID = CKRecordZone.ID(
        zoneName: "com.apple.coredata.cloudkit.zone",
        ownerName: CKCurrentUserDefaultName
    )

    private var lastSyncDate: Date? {
        lastSuccessfulSyncTimestamp > 0 ? Date(timeIntervalSince1970: lastSuccessfulSyncTimestamp) : nil
    }

    private var activeActivities: [SyncActivity] {
        syncActivities.values.filter(\.isActive).sorted { $0.startDate < $1.startDate }
    }

    private var recentActivities: [SyncActivity] {
        Array(
            syncActivities.values
                .filter { !$0.isActive }
                .sorted { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }
                .prefix(6)
        )
    }

    private var overallStatus: String {
        if fellBackToLocal { return "Local Only" }
        if !iCloudConnected { return "Not Connected" }
        if !activeActivities.isEmpty { return "Syncing" }
        if let latest = recentActivities.first {
            return latest.succeeded ? "Up to Date" : "Error"
        }
        return "Idle"
    }

    private var statusColor: Color {
        switch overallStatus {
        case "Up to Date": return .green
        case "Syncing": return .blue
        case "Error", "Local Only", "Not Connected": return .red
        default: return .secondary
        }
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
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if !activeActivities.isEmpty {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(overallStatus)
                                .foregroundStyle(statusColor)
                        }
                    }
                    LabeledContent("Last Sync") {
                        if let lastSyncDate {
                            Text(lastSyncDate.formatted(.dateTime.month().day().hour().minute().second()))
                        } else {
                            Text("—")
                        }
                    }
                }

                if localPhotoCount > 0 || cloudPhotoCount != nil {
                    Section("Sync Progress") {
                        LabeledContent("This Device") {
                            Text("\(localPhotoCount) photos")
                                .contentTransition(.numericText())
                        }

                        if let cloudCount = cloudPhotoCount {
                            LabeledContent("iCloud") {
                                Text("\(cloudCount) photos")
                                    .contentTransition(.numericText())
                            }

                            if cloudCount != localPhotoCount {
                                let total = max(localPhotoCount, cloudCount)
                                let synced = min(localPhotoCount, cloudCount)
                                let remaining = total - synced

                                ProgressView(value: Double(synced), total: Double(max(total, 1)))
                                    .tint(.blue)

                                Text(localPhotoCount > cloudCount
                                     ? "\(remaining) photos waiting to upload"
                                     : "\(remaining) photos waiting to download")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if cloudCount > 0 {
                                Label("All photos synced", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.subheadline)
                            }
                        } else if !activeActivities.isEmpty {
                            HStack {
                                Text("Checking iCloud...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                if !activeActivities.isEmpty {
                    Section("Active") {
                        ForEach(activeActivities) { activity in
                            HStack(spacing: 10) {
                                Image(systemName: activity.kind.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(activity.kind.tint)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.kind.label)
                                        .font(.subheadline.weight(.medium))
                                    Text(activity.startDate, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                }

                if !recentActivities.isEmpty {
                    Section("Recent") {
                        ForEach(recentActivities) { activity in
                            HStack(spacing: 10) {
                                Image(systemName: activity.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(activity.succeeded ? .green : .red)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(activity.kind.label)
                                            .font(.subheadline)
                                        Image(systemName: activity.kind.icon)
                                            .font(.caption2)
                                            .foregroundStyle(activity.kind.tint)
                                    }
                                    if let error = activity.errorMessage {
                                        Text(error)
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if let duration = activity.duration {
                                    Text(String(format: "%.1fs", duration))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
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
                            if isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing || fellBackToLocal || !iCloudConnected)
                } footer: {
                    if let syncMessage {
                        Text(syncMessage)
                    }
                }

                #if DEBUG
                Section("Debug: Raw CloudKit Test") {
                    Button {
                        Task { await createCloudKitTestRecord() }
                    } label: {
                        HStack {
                            Text("Create CloudKit Test Record")
                            Spacer()
                            if isTestingCloudKit {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingCloudKit)

                    if let cloudKitTestResult {
                        Text(cloudKitTestResult)
                            .font(.caption)
                            .foregroundStyle(cloudKitTestResult.hasPrefix("✅") ? .green : .red)
                            .textSelection(.enabled)
                    }

                    Button {
                        Task { await checkSwiftDataZoneStatus() }
                    } label: {
                        Text("Check SwiftData Zone & Schema")
                    }
                    .disabled(isTestingCloudKit)
                }
                #endif
            }
        }
        .navigationTitle("iCloud Sync")
        .task { await checkStatuses() }
        .task { await observeSyncEvents() }
        .task { await refreshCounts() }
        .onDisappear { stopProgressPolling() }
    }

    private func manualSync() async {
        isSyncing = true
        syncMessage = nil

        do {
            try await verifyCloudKitWriteAccess()
        } catch {
            syncMessage = describeCloudKitError(error)
            isSyncing = false
            return
        }

        refreshLocalCount()
        try? modelContext.save()
        syncMessage = "Syncing \(localPhotoCount) photos..."
        startProgressPolling()

        Task {
            try? await Task.sleep(for: .seconds(30))
            if isSyncing {
                isSyncing = false
                if syncMessage?.starts(with: "Syncing") == true {
                    syncMessage = "Sync triggered. Photos will continue syncing in the background."
                }
            }
        }
    }

    private func verifyCloudKitWriteAccess() async throws {
        let database = ckContainer.privateCloudDatabase
        _ = try await database.recordZone(for: syncZoneID)
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
    }

    private func refreshLocalCount() {
        let descriptor = FetchDescriptor<PhotoEntry>()
        withAnimation(.easeInOut(duration: 0.3)) {
            localPhotoCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        }
    }

    private func refreshCounts() async {
        refreshLocalCount()
        let count = await fetchCloudPhotoCount()
        withAnimation(.easeInOut(duration: 0.3)) {
            cloudPhotoCount = count
        }
    }

    private func fetchCloudPhotoCount() async -> Int? {
        let database = ckContainer.privateCloudDatabase
        do {
            let startToken: CKServerChangeToken? = hasFullCloudSnapshot ? cachedChangeToken : nil
            var ids = hasFullCloudSnapshot ? cachedCloudIDs : Set<CKRecord.ID>()
            var token = startToken
            var hasMore = true

            while hasMore {
                let changes = try await database.recordZoneChanges(
                    inZoneWith: syncZoneID,
                    since: token,
                    desiredKeys: []
                )

                for (recordID, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result,
                       modification.record.recordType == "CD_PhotoEntry" {
                        ids.insert(recordID)
                    }
                }

                for deletion in changes.deletions where deletion.recordType == "CD_PhotoEntry" {
                    ids.remove(deletion.recordID)
                }

                token = changes.changeToken
                hasMore = changes.moreComing
            }

            cachedChangeToken = token
            cachedCloudIDs = ids
            hasFullCloudSnapshot = true
            return ids.count
        } catch {
            return nil
        }
    }

    private func startProgressPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            var unchangedCycles = 0
            var lastSeenCloud: Int?
            var lastSeenLocal: Int?

            while !Task.isCancelled {
                refreshLocalCount()
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                let count = await fetchCloudPhotoCount()
                if Task.isCancelled { break }

                withAnimation(.easeInOut(duration: 0.3)) {
                    cloudPhotoCount = count
                }

                if count == lastSeenCloud && localPhotoCount == lastSeenLocal {
                    unchangedCycles += 1
                } else {
                    unchangedCycles = 0
                }
                lastSeenCloud = count
                lastSeenLocal = localPhotoCount

                if unchangedCycles >= 6 && count == localPhotoCount {
                    break
                }

                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopProgressPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func observeSyncEvents() async {
        guard !fellBackToLocal else { return }
        let notifications = NotificationCenter.default.notifications(
            named: NSPersistentCloudKitContainer.eventChangedNotification
        )
        for await notification in notifications {
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { continue }

            let kind: SyncActivity.Kind
            if event.type == .export {
                kind = .exporting
            } else if event.type == .setup {
                kind = .setup
            } else {
                kind = .importing
            }

            let isStarting = event.endDate == nil

            withAnimation(.easeInOut(duration: 0.3)) {
                if isStarting {
                    syncActivities[event.identifier] = SyncActivity(
                        id: event.identifier,
                        kind: kind,
                        startDate: event.startDate
                    )
                } else {
                    if syncActivities[event.identifier] != nil {
                        syncActivities[event.identifier]?.endDate = event.endDate
                        syncActivities[event.identifier]?.succeeded = event.succeeded
                        syncActivities[event.identifier]?.errorMessage = event.error?.localizedDescription
                    } else {
                        var activity = SyncActivity(id: event.identifier, kind: kind, startDate: event.startDate)
                        activity.endDate = event.endDate
                        activity.succeeded = event.succeeded
                        activity.errorMessage = event.error?.localizedDescription
                        syncActivities[event.identifier] = activity
                    }
                }
            }

            if isStarting {
                startProgressPolling()
            } else {
                if event.succeeded, let endDate = event.endDate {
                    lastSuccessfulSyncTimestamp = endDate.timeIntervalSince1970
                }

                if isSyncing && activeActivities.isEmpty {
                    isSyncing = false
                    syncMessage = event.succeeded ? "Sync completed." : (event.error?.localizedDescription ?? "Sync failed.")
                }

                if activeActivities.isEmpty {
                    stopProgressPolling()
                    await refreshCounts()
                }
            }

            let completed = syncActivities.values.filter { !$0.isActive }
            if completed.count > 20 {
                let sorted = completed.sorted { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }
                for activity in sorted.prefix(completed.count - 20) {
                    syncActivities.removeValue(forKey: activity.id)
                }
            }
        }
    }

    #if DEBUG
    private func createCloudKitTestRecord() async {
        isTestingCloudKit = true
        cloudKitTestResult = nil

        let container = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark")
        let database = container.privateCloudDatabase

        let record = CKRecord(recordType: "DaymarkSyncTest")
        record["title"] = "Test from Daymark" as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue

        do {
            let saved = try await database.save(record)
            cloudKitTestResult = "✅ Record saved: \(saved.recordID.recordName)\nGo to CloudKit Console → Development → Schema → Record Types and look for 'DaymarkSyncTest'."
            print("[CloudKit Debug] Test record saved successfully: \(saved.recordID)")
        } catch {
            cloudKitTestResult = "❌ \(formatCloudKitDebugError(error))"
            print("[CloudKit Debug] Test record save FAILED:\n\(formatCloudKitDebugError(error))")
        }

        isTestingCloudKit = false
    }

    private func checkSwiftDataZoneStatus() async {
        isTestingCloudKit = true
        cloudKitTestResult = nil

        let container = CKContainer(identifier: "iCloud.com.shizhengcao.Daymark")
        let database = container.privateCloudDatabase
        var lines: [String] = []

        do {
            let status = try await container.accountStatus()
            lines.append("Account: \(status == .available ? "available" : "status \(status.rawValue)")")
        } catch {
            lines.append("Account check failed: \(error.localizedDescription)")
        }

        lines.append("Fallback to local: \(fellBackToLocal)")

        do {
            let zone = try await database.recordZone(for: syncZoneID)
            lines.append("✅ SwiftData zone exists: \(zone.zoneID.zoneName)")
        } catch let error as CKError where error.code == .zoneNotFound {
            lines.append("❌ SwiftData zone NOT found (com.apple.coredata.cloudkit.zone). Schema was never exported.")
        } catch {
            lines.append("❌ Zone check error: \(formatCloudKitDebugError(error))")
        }

        do {
            let query = CKQuery(recordType: "CD_PhotoEntry", predicate: NSPredicate(value: true))
            let (results, _) = try await database.records(matching: query, inZoneWith: syncZoneID, desiredKeys: [], resultsLimit: 1)
            lines.append("✅ CD_PhotoEntry record type exists, \(results.count) result(s) in first batch")
        } catch let error as CKError where error.code == .unknownItem {
            lines.append("❌ CD_PhotoEntry record type does NOT exist in CloudKit schema")
        } catch {
            lines.append("❌ Query error: \(error.localizedDescription)")
        }

        cloudKitTestResult = lines.joined(separator: "\n")
        isTestingCloudKit = false
    }

    private func formatCloudKitDebugError(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return "Non-CKError: \(error)"
        }
        var parts: [String] = []
        parts.append("CKError code \(ckError.code.rawValue)")
        parts.append(ckError.localizedDescription)
        if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? Error {
            parts.append("Underlying: \(underlying)")
        }
        if let partial = ckError.partialErrorsByItemID {
            for (key, value) in partial {
                parts.append("Partial[\(key)]: \(value)")
            }
        }
        if let retry = ckError.retryAfterSeconds {
            parts.append("Retry after: \(retry)s")
        }
        return parts.joined(separator: "\n")
    }
    #endif
}

private struct SyncActivity: Identifiable {
    let id: UUID
    let kind: Kind
    let startDate: Date
    var endDate: Date?
    var succeeded: Bool = false
    var errorMessage: String?

    var isActive: Bool { endDate == nil }
    var duration: TimeInterval? {
        guard let endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    enum Kind {
        case setup, importing, exporting

        var label: String {
            switch self {
            case .setup: return "Setup"
            case .importing: return "Downloading"
            case .exporting: return "Uploading"
            }
        }
        var icon: String {
            switch self {
            case .setup: return "gearshape.circle.fill"
            case .importing: return "arrow.down.circle.fill"
            case .exporting: return "arrow.up.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .setup: return .orange
            case .importing: return .green
            case .exporting: return .blue
            }
        }
    }
}

#Preview {
    SettingsView(prefersDarkMode: .constant(false))
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
