import Foundation

// MARK: - WidgetData

enum WidgetDataState: String, Codable {
    // Fresh: built from current route data.
    // Fallback: built from cached/partial data when service quality is degraded.
    // Stale: coverage is exhausted and widget should show a recovery hint.
    case fresh
    case fallback
    case stale
}

enum WidgetRecoveryAction: String, Codable {
    case openLiveRoute
    case openRepeatJourney
    case openSetup
}

struct WidgetData: Codable {
    // Single source of truth persisted in App Group storage and read by the widget extension.
    // This payload intentionally includes coverage/signature metadata so writes can be gated.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let transportType: TransportType
    let connections: [WidgetConnection]
    let leaveTimes: [Date]
    let fromStationName: String?
    let toStationName: String?
    let updatedAt: Date
    let generatedAt: Date
    let coverageStart: Date
    let coverageEnd: Date
    let routeSignature: String
    let snapshotSignature: String
    let state: WidgetDataState
    let stateMessage: String?
    let recoveryAction: WidgetRecoveryAction?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        transportType: TransportType,
        connections: [WidgetConnection],
        leaveTimes: [Date],
        fromStationName: String? = nil,
        toStationName: String? = nil,
        updatedAt: Date,
        generatedAt: Date? = nil,
        coverageStart: Date? = nil,
        coverageEnd: Date? = nil,
        routeSignature: String = "",
        snapshotSignature: String = "",
        state: WidgetDataState = .fresh,
        stateMessage: String? = nil,
        recoveryAction: WidgetRecoveryAction? = nil
    ) {
        let inferredRange = Self.inferredCoverageRange(connections: connections, leaveTimes: leaveTimes, fallback: updatedAt)

        self.schemaVersion = schemaVersion
        self.transportType = transportType
        self.connections = connections
        self.leaveTimes = leaveTimes
        self.fromStationName = fromStationName
        self.toStationName = toStationName
        self.updatedAt = updatedAt
        self.generatedAt = generatedAt ?? updatedAt
        self.coverageStart = coverageStart ?? inferredRange.start
        self.coverageEnd = coverageEnd ?? inferredRange.end
        self.routeSignature = routeSignature
        self.snapshotSignature = snapshotSignature
        self.state = state
        self.stateMessage = stateMessage
        self.recoveryAction = recoveryAction
    }

    static let placeholder = WidgetData(
        transportType: .trainCommute,
        connections: [
            WidgetConnection(
                id: "placeholder", lineNumber: "S1", departureTime: Date().addingTimeInterval(900),
                arrivalTime: Date().addingTimeInterval(2100), destination: "Wien Mitte", platform: "3", transfers: 0,
                delay: 0, stopCount: 5, hasReminder: false, isPinned: false
            ),
        ],
        leaveTimes: [Date().addingTimeInterval(600)],
        updatedAt: Date(),
        state: .fresh
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case transportType
        case connections
        case leaveTimes
        case fromStationName
        case toStationName
        case updatedAt
        case generatedAt
        case coverageStart
        case coverageEnd
        case routeSignature
        case snapshotSignature
        case state
        case stateMessage
        case recoveryAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Strict schema: reject unknown versions instead of silently accepting stale payloads.
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported WidgetData schema version \(schemaVersion)."
            )
        }

        self.init(
            schemaVersion: schemaVersion,
            transportType: try container.decode(TransportType.self, forKey: .transportType),
            connections: try container.decode([WidgetConnection].self, forKey: .connections),
            leaveTimes: try container.decode([Date].self, forKey: .leaveTimes),
            fromStationName: try container.decodeIfPresent(String.self, forKey: .fromStationName),
            toStationName: try container.decodeIfPresent(String.self, forKey: .toStationName),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            generatedAt: try container.decodeIfPresent(Date.self, forKey: .generatedAt),
            coverageStart: try container.decodeIfPresent(Date.self, forKey: .coverageStart),
            coverageEnd: try container.decodeIfPresent(Date.self, forKey: .coverageEnd),
            routeSignature: try container.decodeIfPresent(String.self, forKey: .routeSignature) ?? "",
            snapshotSignature: try container.decodeIfPresent(String.self, forKey: .snapshotSignature) ?? "",
            state: try container.decodeIfPresent(WidgetDataState.self, forKey: .state) ?? .fresh,
            stateMessage: try container.decodeIfPresent(String.self, forKey: .stateMessage),
            recoveryAction: try container.decodeIfPresent(WidgetRecoveryAction.self, forKey: .recoveryAction)
        )
    }

    private var scheduledConnections: [(connection: WidgetConnection, leaveTime: Date)] {
        // Persisted arrays are parallel (`connections[i]` belongs to `leaveTimes[i]`).
        // We normalize order so selection logic is deterministic.
        let paired = Array(zip(connections, leaveTimes))
        return paired.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.0.departureTime != rhs.0.departureTime {
                return lhs.0.departureTime < rhs.0.departureTime
            }
            return lhs.0.id < rhs.0.id
        }
    }

    func connection(at date: Date) -> (connection: WidgetConnection, leaveTime: Date)? {
        let scheduled = scheduledConnections
        guard !scheduled.isEmpty else { return nil }

        // Widget always displays the next departure the user still has to leave for.
        for item in scheduled where item.leaveTime > date {
            return item
        }
        return nil
    }

    var isStale: Bool {
        if state == .stale { return true }
        let now = Date()
        if isCoverageExhausted(at: now) { return true }
        // Hard safety timeout: stale if payload was not regenerated for 6h.
        return now.timeIntervalSince(updatedAt) > 6 * 60 * 60
    }

    var isFallback: Bool { state == .fallback }

    func futureConnections(from date: Date) -> [(connection: WidgetConnection, leaveTime: Date)] {
        scheduledConnections.filter { $0.leaveTime > date }
    }

    func hasCoverage(at date: Date) -> Bool {
        coverageStart <= date && coverageEnd >= date
    }

    func isCoverageExhausted(at date: Date) -> Bool {
        date > coverageEnd
    }

    func needsTopUp(referenceDate: Date, targetEnd: Date, minimumFutureConnections: Int = 3) -> Bool {
        // Top-up is required if coverage already ended, ends before target horizon,
        // or if too few usable future departures remain.
        if isCoverageExhausted(at: referenceDate) { return true }
        if coverageEnd < targetEnd { return true }
        return futureConnections(from: referenceDate).count < minimumFutureConnections
    }

    private static func inferredCoverageRange(
        connections: [WidgetConnection],
        leaveTimes: [Date],
        fallback: Date
    ) -> (start: Date, end: Date) {
        let values = leaveTimes + connections.map(\.departureTime)
        guard let start = values.min(), let end = values.max() else { return (fallback, fallback) }
        return (start, max(start, end))
    }
}

// MARK: - WidgetConnection

struct WidgetConnection: Codable {
    let id: String
    let lineNumber: String
    let lineColors: TrainLineColors?
    let departureTime: Date
    let arrivalTime: Date
    let destination: String
    let platform: String?
    let transfers: Int?
    let delay: Int
    let stopCount: Int?
    let hasReminder: Bool
    let isPinned: Bool
    let hasServiceAlert: Bool

    var isDelayed: Bool { delay > 0 }

    init(
        id: String,
        lineNumber: String,
        lineColors: TrainLineColors? = nil,
        departureTime: Date,
        arrivalTime: Date,
        destination: String,
        platform: String?,
        transfers: Int?,
        delay: Int,
        stopCount: Int?,
        hasReminder: Bool = false,
        isPinned: Bool = false,
        hasServiceAlert: Bool = false
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.lineColors = lineColors
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.destination = destination
        self.platform = platform
        self.transfers = transfers
        self.delay = delay
        self.stopCount = stopCount
        self.hasReminder = hasReminder
        self.isPinned = isPinned
        self.hasServiceAlert = hasServiceAlert
    }
}

// MARK: - AppGroupStorage

enum AppGroupStorage {
    // Shared container used by app + widget extension.
    static let suiteName = "group.com.veno.gleis.shared"
    static let widgetDataKey = "widgetData"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func normalizedKeyComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    static func savePrimaryWidgetData(for type: TransportType, data: WidgetData) {
        guard let defaults = sharedDefaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: primaryStorageKey(for: type))
    }

    static func loadPrimaryWidgetData(for type: TransportType) -> WidgetData? {
        guard let defaults = sharedDefaults else { return nil }

        if let primary = defaults.data(forKey: primaryStorageKey(for: type)),
           let decoded = try? JSONDecoder().decode(WidgetData.self, from: primary)
        {
            return decoded
        }

        return nil
    }

    private static func primaryStorageKey(for type: TransportType) -> String {
        "\(widgetDataKey)_\(normalizedKeyComponent(type.rawValue))"
    }
}

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
