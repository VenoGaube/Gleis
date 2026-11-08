import Foundation

// MARK: - ServiceAlertNotifier

/// Delivers disruption alerts for journeys the user has a reminder on.
///
/// This used to live inside `TransportViewModel` with an in-memory dedupe set, which
/// meant alerts were only ever raised while the app was in the foreground and the
/// dedupe state was lost on every launch. Both the foreground refresh and the
/// background task now go through here, sharing persisted dedupe state so the same
/// disruption is announced exactly once.
enum ServiceAlertNotifier {
    /// How long a delivered signature is remembered. Comfortably longer than a
    /// journey, short enough that the stored set cannot grow without bound.
    private static let signatureRetention: TimeInterval = 12 * 60 * 60

    struct DeliveredSignature: Codable, Equatable {
        let signature: String
        let deliveredAt: Date
    }

    /// Delivery runs one at a time. The foreground refresh and the background task
    /// can both reach this, and each does a read-modify-write of the delivered-signature
    /// set — overlapping runs would both see it unmarked and notify twice.
    private static let queue = SerialQueue()

    static func deliverAlerts(
        for reminders: [ScheduledReminder],
        in connections: [TrainConnection],
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        storage: StorageServiceProtocol = LocalStorageService.shared,
        now: Date = Date()
    ) async {
        await queue.run {
            await performDelivery(
                for: reminders,
                in: connections,
                notificationService: notificationService,
                storage: storage,
                now: now
            )
        }
    }

    @discardableResult
    private static func performDelivery(
        for reminders: [ScheduledReminder],
        in connections: [TrainConnection],
        notificationService: NotificationServiceProtocol,
        storage: StorageServiceProtocol,
        now: Date
    ) async -> Int {
        guard !reminders.isEmpty, !connections.isEmpty else { return 0 }

        let connectionsById = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var delivered = loadSignatures(from: storage, now: now)
        let storedSignatureCount = storedCount(in: storage)
        var deliveredLookup = Set(delivered.map(\.signature))
        var sent = 0

        for reminder in reminders where reminder.fiveMinuteWarning || reminder.exactTimeWarning {
            guard let connection = connectionsById[reminder.id] else { continue }
            let activeAlerts = (connection.serviceAlerts ?? []).filter(\.isActive)

            for alert in activeAlerts {
                let signature = signature(reminderId: reminder.id, alert: alert)
                guard deliveredLookup.insert(signature).inserted else { continue }

                do {
                    try await notificationService.scheduleServiceAlertNotification(
                        for: connection,
                        alert: alert,
                        reminderId: reminder.id
                    )
                    delivered.append(DeliveredSignature(signature: signature, deliveredAt: now))
                    sent += 1
                } catch {
                    // Permission denied or scheduling refused; allow a retry next pass.
                    deliveredLookup.remove(signature)
                }
            }
        }

        // Save when entries aged out too, otherwise expired signatures linger in
        // storage for as long as no new alert happens to be delivered.
        if sent > 0 || delivered.count != storedSignatureCount { save(delivered, to: storage) }
        return sent
    }

    // MARK: - Signatures

    /// Identifies an alert by its content, so re-wording or a changed window raises a
    /// fresh notification while a repeat of the same alert stays silent.
    static func signature(reminderId: String, alert: ServiceAlert) -> String {
        let startStamp = alert.startsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let endStamp = alert.endsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        return [
            reminderId,
            alert.id,
            "\(alert.priority)",
            "\(startStamp)",
            "\(endStamp)",
            "\(stableHash(alert.title))",
            "\(stableHash(alert.message))",
        ].joined(separator: "|")
    }

    /// Deterministic FNV-1a. `Hasher` is seeded per process, so it cannot be used
    /// for a value that has to stay stable across launches.
    private static func stableHash(_ value: String) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    // MARK: - Persistence

    private static func loadSignatures(from storage: StorageServiceProtocol, now: Date) -> [DeliveredSignature] {
        let stored: [DeliveredSignature] =
            (try? storage.load(forKey: StorageKey.deliveredServiceAlerts.rawValue)) ?? []
        let cutoff = now.addingTimeInterval(-signatureRetention)
        return stored.filter { $0.deliveredAt >= cutoff }
    }

    private static func storedCount(in storage: StorageServiceProtocol) -> Int {
        let stored: [DeliveredSignature] =
            (try? storage.load(forKey: StorageKey.deliveredServiceAlerts.rawValue)) ?? []
        return stored.count
    }

    private static func save(_ signatures: [DeliveredSignature], to storage: StorageServiceProtocol) {
        try? storage.save(signatures, forKey: StorageKey.deliveredServiceAlerts.rawValue)
    }
}
