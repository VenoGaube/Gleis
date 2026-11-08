import Foundation

// MARK: - ServiceAlertStabilizer

/// Keeps service alerts from flickering between refreshes.
///
/// The provider is inconsistent about alerts: a response may omit them entirely
/// (`nil`, meaning "unknown") or return an empty list (meaning "none"). Trusting
/// either one immediately makes a disruption banner appear and disappear between
/// polls. This holds a known alert until the provider has *authoritatively* reported
/// no alerts `clearConfirmationFetches` times in a row.
struct ServiceAlertStabilizer {
    /// How long a remembered alert survives without being seen again.
    private let retentionWindow: TimeInterval
    /// Consecutive authoritative empty responses needed before an alert is dropped.
    private let clearConfirmationFetches: Int

    private struct State {
        var activeAlerts: [ServiceAlert]
        var lastSeenAt: Date
        var consecutiveAuthoritativeNoAlertFetches: Int
    }

    private var stateByConnectionID: [String: State] = [:]

    init(retentionWindow: TimeInterval = 10 * 60, clearConfirmationFetches: Int = 2) {
        self.retentionWindow = retentionWindow
        self.clearConfirmationFetches = clearConfirmationFetches
    }

    mutating func reset() {
        stateByConnectionID.removeAll()
    }

    mutating func stabilize(
        _ connections: [TrainConnection],
        previous: [TrainConnection],
        now: Date = Date()
    ) -> [TrainConnection] {
        stateByConnectionID = stateByConnectionID.filter {
            now.timeIntervalSince($0.value.lastSeenAt) <= retentionWindow
        }

        let previousActiveByID = Dictionary(
            uniqueKeysWithValues: previous.compactMap { connection -> (String, [ServiceAlert])? in
                let active = (connection.serviceAlerts ?? []).filter(\.isActive)
                return active.isEmpty ? nil : (connection.id, active)
            }
        )

        return connections.map { connection in
            let incomingAlerts = connection.serviceAlerts
            let incomingActive = (incomingAlerts ?? []).filter(\.isActive)

            if !incomingActive.isEmpty {
                stateByConnectionID[connection.id] = State(
                    activeAlerts: incomingActive,
                    lastSeenAt: now,
                    consecutiveAuthoritativeNoAlertFetches: 0
                )
                return connection
            }

            let incomingIsAuthoritativeNoAlert = incomingAlerts != nil
            let priorState = stateByConnectionID[connection.id]
            let priorActiveAlerts = priorState?.activeAlerts ?? previousActiveByID[connection.id]
            guard let priorActiveAlerts, !priorActiveAlerts.isEmpty else { return connection }

            var updatedState = priorState ?? State(
                activeAlerts: priorActiveAlerts,
                lastSeenAt: now,
                consecutiveAuthoritativeNoAlertFetches: 0
            )
            updatedState.activeAlerts = priorActiveAlerts

            if incomingIsAuthoritativeNoAlert {
                updatedState.consecutiveAuthoritativeNoAlertFetches += 1
            } else {
                // An unknown payload (nil) must not clear alerts we know about.
                updatedState.consecutiveAuthoritativeNoAlertFetches = 0
            }

            guard updatedState.consecutiveAuthoritativeNoAlertFetches < clearConfirmationFetches else {
                stateByConnectionID.removeValue(forKey: connection.id)
                return connection
            }

            updatedState.lastSeenAt = now
            stateByConnectionID[connection.id] = updatedState
            return connection.replacingServiceAlerts(with: priorActiveAlerts)
        }
    }
}

// MARK: - TrainConnection + Alerts

extension TrainConnection {
    /// `TrainConnection` is immutable, so carrying a remembered alert forward means
    /// rebuilding the value with the alert list swapped in.
    func replacingServiceAlerts(with alerts: [ServiceAlert]?) -> TrainConnection {
        TrainConnection(
            id: id,
            lineNumber: lineNumber,
            trainType: trainType,
            lineColors: lineColors,
            departureTime: departureTime,
            arrivalTime: arrivalTime,
            departureStation: departureStation,
            arrivalStation: arrivalStation,
            platform: platform,
            delay: delay,
            status: status,
            transfers: transfers,
            legs: legs,
            serviceAlerts: alerts,
            providerConnectionId: providerConnectionId
        )
    }
}
