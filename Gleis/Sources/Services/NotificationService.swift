import Foundation
import UserNotifications

final class NotificationService: NotificationServiceProtocol, @unchecked Sendable {
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
        content.interruptionLevel = preview.interruptionLevel
        content.userInfo[NotificationPayload.deepLinkKey] = NotificationPayload.connectionDeepLink(id: connection.id)
        content.targetContentIdentifier = connection.id

        let leaveTime = config.leaveTime(for: connection, fromStationId: fromStationId)
        let triggerDate = type == .fiveMinuteWarning ? leaveTime.addingTimeInterval(-5 * 60) : leaveTime
        // Returning silently here used to leave the caller showing "Reminder set"
        // for a notification that could never fire.
        guard triggerDate > Date() else { throw GleisError.reminderTimeAlreadyPassed }

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
        let title = type == .fiveMinuteWarning ? "5 min to leave" : "Time to leave"
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
        content.title = "Service alert"
        content.body = serviceAlertBody(for: connection, alert: alert)
        content.sound = .default
        content.categoryIdentifier = "service_alert_\(connection.lineNumber)"
        content.interruptionLevel = .timeSensitive
        content.userInfo[NotificationPayload.deepLinkKey] = NotificationPayload.connectionDeepLink(id: connection.id)
        content.targetContentIdentifier = connection.id

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = serviceAlertNotificationId(
            reminderId: reminderId,
            alertId: alert.id,
            alertPayloadFingerprint: serviceAlertFingerprint(alert)
        )
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    func cancelNotification(id: String) { center.removePendingNotificationRequests(withIdentifiers: [id]) }

    /// Awaits the pending-request query before removing.
    ///
    /// The callback form raced with rescheduling: commute identifiers are
    /// deterministic, so a removal that landed after a re-add deleted the
    /// notification that had just been scheduled.
    private func removePendingNotifications(matching predicate: @Sendable @escaping (String) -> Bool) async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests.map(\.identifier).filter(predicate)
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelServiceAlertNotifications(reminderId: String) async {
        let prefix = "serviceAlert_\(reminderId)_"
        await removePendingNotifications { $0.hasPrefix(prefix) }
    }

    func cancelAllCommuteNotifications() async {
        await removePendingNotifications { $0.hasPrefix("commute_") }
    }

    func scheduleCommuteNotification(
        route: SavedCommuteRoute,
        day: Weekday,
        schedule: DaySchedule,
        direction: CommuteDirection,
        config _: RouteConfiguration,
        occurrence: CommuteOccurrencePlanner.Occurrence,
        occurrenceIndex: Int
    ) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { throw GleisError.notificationPermissionDenied }
        guard route.fromStation(for: direction) != nil,
              let destination = route.toStation(for: direction)?.name else { return }

        // Repeat journeys always use both notification types.
        try await scheduleDatedNotification(
            id: commuteNotificationId(direction: direction, day: day, suffix: "5min", occurrenceIndex: occurrenceIndex),
            fireDate: occurrence.leaveDate.addingTimeInterval(-5 * 60),
            title: "5 min to leave",
            body: "\(schedule.lineNumber) to \(destination) leaves at \(schedule.departureTimeString).",
            level: .active,
            deepLink: NotificationPayload.repeatScheduleDeepLink
        )
        try await scheduleDatedNotification(
            id: commuteNotificationId(direction: direction, day: day, suffix: "leave", occurrenceIndex: occurrenceIndex),
            fireDate: occurrence.leaveDate,
            title: "Time to leave",
            body: "\(schedule.lineNumber) to \(destination) leaves at \(schedule.departureTimeString).",
            level: .timeSensitive,
            deepLink: NotificationPayload.repeatScheduleDeepLink
        )
    }

    /// Identifiers stay prefixed with `commute_` so a bulk cancel still finds them.
    private func commuteNotificationId(
        direction: CommuteDirection,
        day: Weekday,
        suffix: String,
        occurrenceIndex: Int
    ) -> String {
        let base = "commute_\(direction.rawValue)_\(day.rawValue)_\(suffix)"
        return occurrenceIndex == 0 ? base : "\(base)_\(occurrenceIndex)"
    }

    private func scheduleDatedNotification(
        id: String,
        fireDate: Date,
        title: String,
        body: String,
        level: UNNotificationInterruptionLevel,
        deepLink: String
    ) async throws {
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = level
        content.userInfo[NotificationPayload.deepLinkKey] = deepLink

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func notificationBody(
        for connection: TrainConnection, config: RouteConfiguration, type: NotificationType
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let departureStr = formatter.string(from: config.effectiveDepartureTime(for: connection))
        let delaySuffix = connection.delay > 0 ? " (+\(connection.delay) min)" : ""
        var platformSuffix = ""
        if let platform = connection.platform, !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            platformSuffix = " from platform \(platform)"
        }
        let departureDetail = "leaves at \(departureStr)\(delaySuffix)\(platformSuffix)."

        return type == .fiveMinuteWarning
            ? "\(config.notificationSettings.customMessage)\n\(connection.lineNumber) \(departureDetail)"
            : "\(connection.lineNumber) to \(connection.arrivalStation.name) \(departureDetail)"
    }

    private func serviceAlertBody(for connection: TrainConnection, alert: ServiceAlert) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        var body = "\(connection.lineNumber) to \(connection.arrivalStation.name) at \(formatter.string(from: connection.departureTime))"
        let alertTitle = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alertTitle.isEmpty { body += ": \(alertTitle)" }
        if let until = alert.endsAt { body += ", until \(formatter.string(from: until))" }
        return body + ". Tap for details."
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
}
