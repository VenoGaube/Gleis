import Foundation

// MARK: - ConnectionIdentity

/// Normalisation shared by connection de-duplication and reminder re-matching.
///
/// The provider returns the same journey under different ids across pages and
/// refreshes, with cosmetic differences in line and platform spelling, so both
/// features need to compare them the same way.
enum ConnectionIdentity {
    static func normalizeLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static func normalizePlatform(_ platform: String?) -> String {
        (platform ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    static func minuteTimestamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return String(Int(date.timeIntervalSince1970 / 60))
    }

    /// Identifies a journey by what it physically is — stations, times to the minute,
    /// and its legs — rather than by the provider's volatile connection id.
    static func signature(for connection: TrainConnection) -> String {
        let legSignature = connection.legs.map(legSignature).joined(separator: ";")
        return [
            connection.departureStation.id,
            connection.arrivalStation.id,
            minuteTimestamp(connection.departureTime),
            minuteTimestamp(connection.arrivalTime),
            "\(connection.transfers)",
            legSignature,
        ].joined(separator: "|")
    }

    /// An id that is the same for the same trip on every fetch and different for different trips.
    /// ÖBB gives one id to several trips that share a main train but use different feeder trains, so the id
    /// alone would make Gleis drop real trips. Scheduled times keep it stable while delays change.
    static func tripId(providerId: String, legs: [ConnectionLeg]) -> String {
        let tripKey = legs.filter { !$0.isWalking }.map { leg in
            let scheduledDeparture = leg.departureTime.map {
                $0.addingTimeInterval(-TimeInterval((leg.departureDelayMinutes ?? 0) * 60))
            }
            return [normalizeLine(leg.lineNumber), leg.from.id, leg.to.id, minuteTimestamp(scheduledDeparture)]
                .joined(separator: "~")
        }.joined(separator: ";")
        return "\(providerId)-\(stableHash(tripKey))"
    }

    // FNV-1a, because Swift's Hasher is seeded per launch and the id must survive restarts and the disk cache.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func legSignature(_ leg: ConnectionLeg) -> String {
        [
            leg.isWalking ? "W" : "T",
            normalizeLine(leg.lineNumber),
            leg.from.id,
            leg.to.id,
            minuteTimestamp(leg.departureTime),
            minuteTimestamp(leg.arrivalTime),
        ].joined(separator: "~")
    }
}

// MARK: - ConnectionDeduplicator

/// Collapses duplicate representations of the same journey, keeping the richest copy.
///
/// Stateless: everything it needs about the user's reminders and pin is passed in,
/// so the same inputs always produce the same output.
enum ConnectionDeduplicator {
    /// The user-state that makes one duplicate preferable to another. Keeping the copy
    /// the user already has a reminder or pin against avoids breaking those references.
    struct PreferenceContext {
        let pinnedConnectionId: String?
        let reminderIds: Set<String>
        let savedRoute: SavedCommuteRoute
        let previousIds: Set<String>

        func hasReminder(for connection: TrainConnection) -> Bool {
            reminderIds.contains(connection.id) || savedRoute.hasActiveReminder(for: connection)
        }
    }

    static func deduplicate(_ connections: [TrainConnection], context: PreferenceContext) -> [TrainConnection] {
        guard connections.count > 1 else { return connections }

        var bestBySignature: [String: TrainConnection] = [:]
        for connection in connections {
            let signature = ConnectionIdentity.signature(for: connection)
            guard let existing = bestBySignature[signature] else {
                bestBySignature[signature] = connection
                continue
            }
            if shouldPrefer(connection, over: existing, context: context) {
                bestBySignature[signature] = connection
            }
        }

        return bestBySignature.values.sorted { lhs, rhs in
            if lhs.departureTime != rhs.departureTime { return lhs.departureTime < rhs.departureTime }
            if lhs.arrivalTime != rhs.arrivalTime { return lhs.arrivalTime < rhs.arrivalTime }
            return lhs.id < rhs.id
        }
    }

    private static func shouldPrefer(
        _ candidate: TrainConnection,
        over current: TrainConnection,
        context: PreferenceContext
    ) -> Bool {
        let candidateScore = preferenceScore(for: candidate, context: context)
        let currentScore = preferenceScore(for: current, context: context)
        if candidateScore != currentScore { return candidateScore > currentScore }
        // Tie-break on id so the result is stable across refreshes.
        return candidate.id < current.id
    }

    private static func preferenceScore(for connection: TrainConnection, context: PreferenceContext) -> Int {
        var score = 0

        if context.pinnedConnectionId == connection.id { score += 1000 }
        if context.hasReminder(for: connection) { score += 800 }
        if context.previousIds.contains(connection.id) { score += 300 }
        if connection.serviceAlerts != nil { score += 80 }
        score += (connection.serviceAlerts ?? []).filter(\.isActive).count * 40
        if !ConnectionIdentity.normalizePlatform(connection.platform).isEmpty { score += 2 }

        score += connection.legs.reduce(0) { partial, leg in
            var legScore = 0
            if !leg.isWalking { legScore += 10 }
            if leg.stopCount != nil { legScore += 5 }
            if !leg.intermediateStops.isEmpty { legScore += 5 }
            if !ConnectionIdentity.normalizePlatform(leg.platform).isEmpty { legScore += 2 }
            return partial + legScore
        }

        return score
    }
}
