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

        let preview = notificationPreview(for: connection, config: config, type: type)
        let content = UNMutableNotificationContent()
        content.title = preview.title
        content.body = preview.body
        content.sound = config.notificationSettings.soundEnabled ? .default : nil
        content.categoryIdentifier = config.transportType.rawValue
        content.interruptionLevel = preview.interruptionLevel

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

    func notificationPreview(
        for connection: TrainConnection,
        config: RouteConfiguration,
        type: NotificationType
    ) -> (title: String, body: String, interruptionLevel: UNNotificationInterruptionLevel) {
        let title = type == .fiveMinuteWarning ? "⏰ 5 Minutes" : "🚨 GO!"
        let body = notificationBody(for: connection, config: config, type: type)
        let interruptionLevel: UNNotificationInterruptionLevel = type == .exactTime ? .timeSensitive : .active
        return (title: title, body: body, interruptionLevel: interruptionLevel)
    }

    func scheduleServiceAlertNotification(
        for connection: TrainConnection,
        alert: ServiceAlert,
        reminderId: String
    ) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { throw GleisError.notificationPermissionDenied }
        guard alert.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = "⚠️ Service Alert"
        content.body = serviceAlertBody(for: connection, alert: alert)
        content.sound = .default
        content.categoryIdentifier = "service_alert_\(connection.lineNumber)"
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = serviceAlertNotificationId(
            reminderId: reminderId,
            alertId: alert.id,
            alertPayloadFingerprint: serviceAlertFingerprint(alert)
        )
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    func cancelNotification(id: String) { center.removePendingNotificationRequests(withIdentifiers: [id]) }

    func cancelServiceAlertNotifications(reminderId: String) {
        let prefix = "serviceAlert_\(reminderId)_"
        center.getPendingNotificationRequests { requests in
            let identifiers = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            guard !identifiers.isEmpty else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

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
        let normalized = normalizedWeeklyTrigger(weekday: weekday, minutes: minutes)

        var components = DateComponents()
        components.weekday = normalized.weekday
        components.hour = normalized.minutes / 60
        components.minute = normalized.minutes % 60

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
        var detailParts: [String] = []
        if connection.delay > 0 { detailParts.append("+\(connection.delay) min delay") }
        if let platform = connection.platform, !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detailParts.append("Platform \(platform)")
        }
        let detailSuffix = detailParts.isEmpty ? "" : " (\(detailParts.joined(separator: ", ")))"

        return type == .fiveMinuteWarning
            ? "\(config.notificationSettings.customMessage)\n\(connection.lineNumber) departs at \(departureStr)\(detailSuffix)"
            : "Catch \(connection.lineNumber) at \(departureStr)\(detailSuffix) → \(connection.arrivalStation.name)"
    }

    private func serviceAlertBody(for connection: TrainConnection, alert: ServiceAlert) -> String {
        var parts: [String] = ["\(connection.lineNumber) to \(connection.arrivalStation.name)"]
        if !alert.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(alert.title) }
        if let until = alert.endsAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            parts.append("until \(formatter.string(from: until))")
        }
        return parts.joined(separator: " • ")
    }

    private func serviceAlertNotificationId(
        reminderId: String,
        alertId: String,
        alertPayloadFingerprint: String
    ) -> String {
        "serviceAlert_\(reminderId)_\(alertId)_\(alertPayloadFingerprint)"
    }

    private func serviceAlertFingerprint(_ alert: ServiceAlert) -> String {
        let endStamp = alert.endsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let startStamp = alert.startsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let titleHash = stableHash(alert.title)
        let messageHash = stableHash(alert.message)
        return "\(alert.priority)_\(startStamp)_\(endStamp)_\(titleHash)_\(messageHash)"
    }

    private func stableHash(_ value: String) -> UInt64 {
        // Deterministic 64-bit FNV-1a hash for notification deduping identifiers.
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    private func normalizedWeeklyTrigger(weekday: Int, minutes: Int) -> (weekday: Int, minutes: Int) {
        var normalizedWeekday = weekday
        var normalizedMinutes = minutes
        let dayMinutes = 24 * 60

        while normalizedMinutes < 0 {
            normalizedMinutes += dayMinutes
            normalizedWeekday -= 1
            if normalizedWeekday < 1 { normalizedWeekday = 7 }
        }

        while normalizedMinutes >= dayMinutes {
            normalizedMinutes -= dayMinutes
            normalizedWeekday += 1
            if normalizedWeekday > 7 { normalizedWeekday = 1 }
        }

        return (normalizedWeekday, normalizedMinutes)
    }
}
