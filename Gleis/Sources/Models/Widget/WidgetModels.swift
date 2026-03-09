import Foundation

// MARK: - WidgetSnapshotBuilder

struct WidgetSnapshotCandidate {
    // Intermediate representation before writing WidgetData.
    let connection: TrainConnection
    let leaveTime: Date
    let isSelected: Bool
    let isPinned: Bool
}

enum WidgetSnapshotBuilder {
    // Hard cap to keep payload size predictable and avoid storing unnecessary horizon data.
    static let maxStoredConnectionLimit = 60
    // Minimum expected overnight coverage count (30% of the cap).
    static let overnightConnectionFloor = 18 // 30% of 60

    static func routeSignature(startStationId: String?, endStationId: String?) -> String {
        // Route identity used to invalidate stale snapshots after station changes.
        "\(startStationId ?? "nil")->\(endStationId ?? "nil")"
    }

    static func morningCoverageWindow(from referenceDate: Date) -> (start: Date, end: Date) {
        // Target horizon: keep departures available for wake-up window.
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: referenceDate)
        let startOffsetMinutes = 4 * 60 + 30
        let endOffsetMinutes = 10 * 60

        let todayStart = calendar.date(byAdding: .minute, value: startOffsetMinutes, to: dayStart) ?? referenceDate
        let todayEnd = calendar.date(byAdding: .minute, value: endOffsetMinutes, to: dayStart) ?? referenceDate
        if referenceDate < todayEnd {
            return (todayStart, todayEnd)
        }

        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let nextWindowStart = calendar.date(byAdding: .minute, value: startOffsetMinutes, to: nextDayStart)
            ?? referenceDate
        let nextWindowEnd = calendar.date(byAdding: .minute, value: endOffsetMinutes, to: nextDayStart)
            ?? referenceDate
        return (nextWindowStart, nextWindowEnd)
    }

    static func targetConnectionFloor(referenceDate: Date, targetEnd: Date, cap: Int = maxStoredConnectionLimit) -> Int {
        // Base target is 30% of cap; require slightly more for long overnight spans.
        let floor = max(1, Int(ceil(Double(cap) * 0.3)))
        let durationHours = max(0, targetEnd.timeIntervalSince(referenceDate)) / 3600
        if durationHours >= 8 {
            return min(cap, max(floor, floor + 6))
        }
        return floor
    }

    static func selectCandidates(
        from sourceConnections: [TrainConnection],
        config: RouteConfiguration,
        savedRoute: SavedCommuteRoute,
        reminderIds: Set<String>,
        pinnedConnectionId: String?,
        referenceDate: Date,
        limit: Int = maxStoredConnectionLimit
    ) -> [WidgetSnapshotCandidate] {
        // Selection pipeline:
        // 1) remove excluded train types
        // 2) dedupe by connection id
        // 3) compute leave-time + reminder/pin flags
        // 4) prefer non-pinned departures; fallback to including pin if needed
        let excluded = config.excludedTrainTypes
        let filtered = excluded.isEmpty
            ? sourceConnections
            : sourceConnections.filter { !excluded.contains($0.trainType) }
        let deduplicated = deduplicatedByConnectionID(filtered)
        let candidates = deduplicated.map { connection in
            let leaveTime = config.leaveTime(for: connection, fromStationId: config.startStation?.id)
            let isSelected = reminderIds.contains(connection.id) || savedRoute.hasActiveReminder(for: connection)
            let isPinned = pinnedConnectionId == connection.id
            return WidgetSnapshotCandidate(
                connection: connection,
                leaveTime: leaveTime,
                isSelected: isSelected,
                isPinned: isPinned
            )
        }

        let routeOrdered = sortedCandidates(
            from: candidates,
            excludingPinned: true,
            pinnedConnectionId: pinnedConnectionId,
            referenceDate: referenceDate
        )
        if !routeOrdered.isEmpty {
            return Array(routeOrdered.prefix(limit))
        }

        let includingPinned = sortedCandidates(
            from: candidates,
            excludingPinned: false,
            pinnedConnectionId: pinnedConnectionId,
            referenceDate: referenceDate
        )
        return Array(includingPinned.prefix(limit))
    }

    static func makeWidgetConnection(_ candidate: WidgetSnapshotCandidate) -> WidgetConnection {
        // Collapse full transport model into compact widget-facing fields.
        let connection = candidate.connection
        let stopCount = connection.legs.first { !$0.isWalking }?.stopCount
        return WidgetConnection(
            id: connection.id,
            lineNumber: connection.lineNumber,
            lineColors: connection.lineColors,
            departureTime: connection.departureTime,
            arrivalTime: connection.arrivalTime,
            destination: connection.arrivalStation.name,
            platform: connection.platform,
            transfers: connection.transfers,
            delay: connection.delay,
            stopCount: stopCount,
            hasReminder: candidate.isSelected,
            isPinned: candidate.isPinned,
            hasServiceAlert: (connection.serviceAlerts ?? []).contains(where: \.isActive)
        )
    }

    static func coverageRange(
        for candidates: [WidgetSnapshotCandidate],
        fallback: Date
    ) -> (start: Date, end: Date) {
        // Coverage is based on both leave-time and departure-time boundaries.
        let coverageValues = candidates.map(\.leaveTime) + candidates.map { $0.connection.departureTime }
        guard let start = coverageValues.min(), let end = coverageValues.max() else { return (fallback, fallback) }
        return (start, max(start, end))
    }

    static func snapshotSignature(
        routeSignature: String,
        stateSignature: String,
        candidates: [WidgetSnapshotCandidate],
        coverageRange: (start: Date, end: Date)
    ) -> String {
        // Deterministic signature over only widget-relevant fields.
        // Used to skip redundant writes + timeline reloads.
        let coverageSignature = candidates.isEmpty
            ? "empty"
            : "\(Int(coverageRange.start.timeIntervalSince1970))-\(Int(coverageRange.end.timeIntervalSince1970))"
        let itemsSignature = candidates.map { candidate in
            let connection = candidate.connection
            let departure = Int(connection.departureTime.timeIntervalSince1970)
            let leave = Int(candidate.leaveTime.timeIntervalSince1970)
            let hasServiceAlert = (connection.serviceAlerts ?? []).contains(where: \.isActive)
            return [
                connection.id,
                String(departure),
                String(leave),
                String(connection.delay),
                normalizePlatform(connection.platform),
                hasServiceAlert ? "1" : "0",
                candidate.isSelected ? "1" : "0",
                candidate.isPinned ? "1" : "0",
            ].joined(separator: "#")
        }.joined(separator: "|")

        return "\(routeSignature)|\(stateSignature)|\(coverageSignature)|\(itemsSignature)"
    }

    static func deduplicatedByConnectionID(_ connections: [TrainConnection]) -> [TrainConnection] {
        // Stable dedupe: first occurrence by chronological order wins.
        var seenIDs = Set<String>()
        var deduplicated: [TrainConnection] = []
        for connection in connections.sorted(by: {
            if $0.departureTime != $1.departureTime { return $0.departureTime < $1.departureTime }
            return $0.id < $1.id
        }) {
            guard seenIDs.insert(connection.id).inserted else { continue }
            deduplicated.append(connection)
        }
        return deduplicated
    }

    private static func sortedCandidates(
        from candidates: [WidgetSnapshotCandidate],
        excludingPinned: Bool,
        pinnedConnectionId: String?,
        referenceDate: Date
    ) -> [WidgetSnapshotCandidate] {
        candidates
            .filter { candidate in
                // Widget should only surface departures still actionable in the future.
                guard candidate.connection.departureTime > referenceDate, candidate.leaveTime > referenceDate else {
                    return false
                }
                if excludingPinned {
                    return candidate.connection.id != pinnedConnectionId && !candidate.isPinned
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.connection.departureTime != rhs.connection.departureTime {
                    return lhs.connection.departureTime < rhs.connection.departureTime
                }
                return lhs.connection.id < rhs.connection.id
            }
    }

    private static func normalizePlatform(_ platform: String?) -> String {
        // Normalize platform text so equivalent values produce identical signatures.
        (platform ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}
