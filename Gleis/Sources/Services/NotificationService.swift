import Foundation
import UserNotifications

final class NotificationService: NotificationServiceProtocol {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func scheduleNotification(
        for connection: TrainConnection, config: RouteConfiguration, type: NotificationType, fromStationId: String?
    ) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { throw GleisError.notificationPermissionDenied }

        let content = UNMutableNotificationContent()
        content.title = type == .fiveMinuteWarning ? "⏰ 5 Minutes" : "🚨 GO!"
        content.body = notificationBody(for: connection, config: config, type: type)
        content.sound = config.notificationSettings.soundEnabled ? .default : nil
        content.categoryIdentifier = config.transportType.rawValue
        content.interruptionLevel = type == .exactTime ? .timeSensitive : .active

        let leaveTime = config.leaveTime(for: connection, fromStationId: fromStationId)
        let triggerDate = type == .fiveMinuteWarning ? leaveTime.addingTimeInterval(-5 * 60) : leaveTime
        guard triggerDate > Date() else { return }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(
            UNNotificationRequest(identifier: "\(connection.id)_\(type)", content: content, trigger: trigger))
    }

    func cancelNotification(id: String) { center.removePendingNotificationRequests(withIdentifiers: [id]) }

    func cancelCommuteNotification(day: Weekday, direction: CommuteDirection) {
        let ids = [
            "commute_\(direction.rawValue)_\(day.rawValue)_5min", "commute_\(direction.rawValue)_\(day.rawValue)_leave",
        ]
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAllCommuteNotifications() {
        center.getPendingNotificationRequests { requests in
            let commuteIds = requests.filter { $0.identifier.hasPrefix("commute_") }.map(\.identifier)
            self.center.removePendingNotificationRequests(withIdentifiers: commuteIds)
        }
    }

    func scheduleCommuteNotification(
        route: SavedCommuteRoute, day: Weekday, schedule: DaySchedule, direction: CommuteDirection,
        config: RouteConfiguration
    ) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { throw GleisError.notificationPermissionDenied }
        guard let fromStation = route.fromStation(for: direction),
              let destination = route.toStation(for: direction)?.name else { return }

        let walkingTime = config.travelTime(for: fromStation.id) ?? config.walkingTimeMinutes
        let bufferTime = config.bufferTime(for: fromStation.id) ?? config.bufferTimeMinutes
        let leaveMinutes = schedule.departureHour * 60 + schedule.departureMinute - walkingTime - bufferTime

        // Repeat journeys always use both notification types.
        try await scheduleWeeklyNotification(
            id: "commute_\(direction.rawValue)_\(day.rawValue)_5min", weekday: day.rawValue, minutes: leaveMinutes - 5,
            title: "⏰ 5 Minutes",
            body: "\(schedule.lineNumber) to \(destination) departs at \(schedule.departureTimeString)", level: .active
        )
        try await scheduleWeeklyNotification(
            id: "commute_\(direction.rawValue)_\(day.rawValue)_leave", weekday: day.rawValue, minutes: leaveMinutes,
            title: "🚨 GO!", body: "Catch \(schedule.lineNumber) at \(schedule.departureTimeString) → \(destination)",
            level: .timeSensitive
        )
    }

    private func scheduleWeeklyNotification(
        id: String, weekday: Int, minutes: Int, title: String, body: String, level: UNNotificationInterruptionLevel
    ) async throws {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = minutes / 60
        components.minute = minutes % 60

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = level

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func notificationBody(
        for connection: TrainConnection, config: RouteConfiguration, type: NotificationType
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let departureStr = formatter.string(from: config.effectiveDepartureTime(for: connection))
        return type == .fiveMinuteWarning
            ? "\(config.notificationSettings.customMessage)\n\(connection.lineNumber) departs at \(departureStr)"
            : "Catch \(connection.lineNumber) at \(departureStr) → \(connection.arrivalStation.name)"
    }
}
