import Foundation
import UserNotifications

struct NotificationManager {
    private static let reminderIdentifier = "daymark.daily.reminder"

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func scheduleDailyReminder(at hour: Int, minute: Int) async {
        let center = UNUserNotificationCenter.current()

        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Daymark"
        content.body = "Have you marked today? Take a moment to capture your day."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: reminderIdentifier, content: content, trigger: trigger)

        try? await center.add(request)
    }

    static func cancelDailyReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
    }

    static func isReminderScheduled() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        return requests.contains { $0.identifier == reminderIdentifier }
    }
}
