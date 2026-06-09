#if DEBUG
import CoreData
import Foundation
import OSLog
import SwiftData

@MainActor
enum MetadataSyncExperiment {
    static let entryID = "daymark-metadata-sync-experiment-v1"
    private static let experimentDay = Date(timeIntervalSince1970: 4_102_444_800)
    private static let logger = Logger(
        subsystem: "com.shizhengcao.Daymark",
        category: "MetadataSyncExperiment"
    )

    static func run(arguments: [String], in modelContext: ModelContext) async {
        guard let action = value(after: "-metadataExperimentAction", in: arguments) else {
            emit("DAYMARK_METADATA_EXPERIMENT_ERROR missing_action")
            return
        }

        let eventTask = observeCloudKitEvents()
        defer { eventTask.cancel() }

        do {
            switch action {
            case "create":
                let entry = try fetchEntry(in: modelContext) ?? PhotoEntry(
                    id: entryID,
                    day: experimentDay
                )
                if entry.modelContext == nil {
                    modelContext.insert(entry)
                }
                applyExperimentMetadata(
                    to: entry,
                    caption: value(after: "-metadataExperimentCaption", in: arguments) ?? "created"
                )
                try modelContext.save()
                printSnapshot(action: action, entry: entry)

            case "edit":
                guard let entry = try fetchEntry(in: modelContext) else {
                    emit("DAYMARK_METADATA_EXPERIMENT_ERROR edit_missing_entry")
                    return
                }
                applyExperimentMetadata(
                    to: entry,
                    caption: value(after: "-metadataExperimentCaption", in: arguments) ?? "edited"
                )
                try modelContext.save()
                printSnapshot(action: action, entry: entry)

            case "delete":
                guard let entry = try fetchEntry(in: modelContext) else {
                    emit("DAYMARK_METADATA_EXPERIMENT_RESULT action=delete found=false")
                    return
                }
                modelContext.delete(entry)
                try modelContext.save()
                emit("DAYMARK_METADATA_EXPERIMENT_RESULT action=delete found=false")

            case "wait":
                let expected = value(after: "-metadataExperimentExpected", in: arguments) ?? "present"
                let timeout = TimeInterval(
                    value(after: "-metadataExperimentTimeout", in: arguments) ?? "90"
                ) ?? 90
                await waitForExpected(expected, timeout: timeout, in: modelContext)

            case "snapshot":
                printSnapshot(action: action, entry: try fetchEntry(in: modelContext))

            default:
                emit("DAYMARK_METADATA_EXPERIMENT_ERROR unknown_action=\(action)")
            }

            let settleSeconds = TimeInterval(
                value(after: "-metadataExperimentSettle", in: arguments) ?? "0"
            ) ?? 0
            if settleSeconds > 0 {
                try? await Task.sleep(for: .seconds(settleSeconds))
                printSnapshot(action: "\(action)_settled", entry: try fetchEntry(in: modelContext))
            }
        } catch {
            emit("DAYMARK_METADATA_EXPERIMENT_ERROR action=\(action) error=\(quoted(error.localizedDescription))")
        }
    }

    private static func applyExperimentMetadata(to entry: PhotoEntry, caption: String) {
        entry.day = experimentDay
        entry.caption = caption
        entry.city = "Metadata Lab"
        entry.countryCode = "US"
        entry.countryName = "United States"
        entry.timezone = "UTC"
        entry.latitude = 37.3349
        entry.longitude = -122.0090
    }

    private static func waitForExpected(
        _ expected: String,
        timeout: TimeInterval,
        in modelContext: ModelContext
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline, !Task.isCancelled {
            do {
                let entry = try fetchEntry(in: modelContext)
                if matches(entry: entry, expected: expected) {
                    printSnapshot(action: "wait", entry: entry, expected: expected, matched: true)
                    return
                }
            } catch {
                emit("DAYMARK_METADATA_EXPERIMENT_ERROR action=wait error=\(quoted(error.localizedDescription))")
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }

        let entry = try? fetchEntry(in: modelContext)
        printSnapshot(action: "wait", entry: entry ?? nil, expected: expected, matched: false)
    }

    private static func matches(entry: PhotoEntry?, expected: String) -> Bool {
        switch expected {
        case "present":
            return entry != nil
        case "absent":
            return entry == nil
        default:
            guard expected.hasPrefix("caption:") else { return false }
            return entry?.caption == String(expected.dropFirst("caption:".count))
        }
    }

    private static func fetchEntry(in modelContext: ModelContext) throws -> PhotoEntry? {
        let id = entryID
        var descriptor = FetchDescriptor<PhotoEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func printSnapshot(
        action: String,
        entry: PhotoEntry?,
        expected: String? = nil,
        matched: Bool? = nil
    ) {
        var fields = [
            "action=\(action)",
            "found=\(entry != nil)",
            "caption=\(quoted(entry?.caption ?? ""))",
            "city=\(quoted(entry?.city ?? ""))",
        ]
        if let expected {
            fields.append("expected=\(quoted(expected))")
        }
        if let matched {
            fields.append("matched=\(matched)")
        }
        emit("DAYMARK_METADATA_EXPERIMENT_RESULT \(fields.joined(separator: " "))")
    }

    private static func observeCloudKitEvents() -> Task<Void, Never> {
        Task {
            let notifications = NotificationCenter.default.notifications(
                named: NSPersistentCloudKitContainer.eventChangedNotification
            )
            for await notification in notifications {
                guard !Task.isCancelled,
                      let event = notification.userInfo?[
                        NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                      ] as? NSPersistentCloudKitContainer.Event else {
                    continue
                }
                let phase = event.endDate == nil ? "started" : "finished"
                let error = event.error?.localizedDescription ?? ""
                emit(
                    "DAYMARK_METADATA_CLOUD_EVENT " +
                    "type=\(eventTypeName(event.type)) " +
                    "phase=\(phase) " +
                    "succeeded=\(event.succeeded) " +
                    "error=\(quoted(error))"
                )
            }
        }
    }

    private static func eventTypeName(
        _ type: NSPersistentCloudKitContainer.EventType
    ) -> String {
        switch type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "unknown"
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func emit(_ message: String) {
        print(message)
        logger.notice("\(message, privacy: .public)")
    }
}
#endif
