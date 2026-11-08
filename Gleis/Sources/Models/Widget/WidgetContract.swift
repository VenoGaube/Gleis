import Foundation

// MARK: - WidgetData

enum WidgetDataState: String, Codable {
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
                id: "placeholder",
                lineNumber: "S1",
                departureTime: Date().addingTimeInterval(900),
                arrivalTime: Date().addingTimeInterval(2100),
                destination: "Wien Mitte",
                platform: "3",
                transfers: 0,
                delay: 0,
                stopCount: 5,
                hasReminder: false,
                isPinned: false
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
        let paired = Array(zip(connections, leaveTimes))
        return paired.sorted { lhs, rhs in
            if lhs.0.departureTime != rhs.0.departureTime { return lhs.0.departureTime < rhs.0.departureTime }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.id < rhs.0.id
        }
    }

    func connection(at date: Date) -> (connection: WidgetConnection, leaveTime: Date)? {
        let scheduled = scheduledConnections
        guard !scheduled.isEmpty else { return nil }

        for item in scheduled where item.leaveTime > date {
            return item
        }
        return nil
    }

    var isStale: Bool {
        if state == .stale { return true }
        let now = Date()
        if isCoverageExhausted(at: now) { return true }
        return now.timeIntervalSince(updatedAt) > 6 * 60 * 60
    }

    var isFallback: Bool { state == .fallback }

    var connectionCount: Int { min(connections.count, leaveTimes.count) }

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
        if isCoverageExhausted(at: referenceDate) { return true }
        if coverageEnd < targetEnd { return true }
        return futureConnections(from: referenceDate).count < minimumFutureConnections
    }

    var routeText: String {
        let from = WidgetData.normalizedStationName(fromStationName)
        let to = WidgetData.normalizedStationName(toStationName)
        if let from, let to { return "\(from) → \(to)" }
        return "From → To"
    }

    var compactRouteText: String {
        let from = WidgetData.normalizedStationName(fromStationName)
        let to = WidgetData.normalizedStationName(toStationName)
        if let from, let to {
            let fromCompact = from.components(separatedBy: .whitespaces).first ?? from
            let toCompact = to.components(separatedBy: .whitespaces).first ?? to
            return "\(fromCompact) → \(toCompact)"
        }
        return "From → To"
    }

    static func emptyHintText(for data: WidgetData?) -> String {
        if let message = data?.stateMessage, !message.isEmpty { return message }
        switch data?.state {
        case .fallback:
            return "Open the app to refresh."
        case .stale:
            return "Check again soon or update route."
        default:
            return "Tap to set up your commute"
        }
    }

    private static func normalizedStationName(_ name: String?) -> String? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
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
    let isCancelled: Bool

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
        hasServiceAlert: Bool = false,
        isCancelled: Bool = false
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
        self.isCancelled = isCancelled
    }

    private enum CodingKeys: String, CodingKey {
        case id, lineNumber, lineColors, departureTime, arrivalTime, destination, platform
        case transfers, delay, stopCount, hasReminder, isPinned, hasServiceAlert, isCancelled
    }

    /// Decoded leniently for `isCancelled` so a snapshot written by an older build
    /// still loads instead of blanking the widget until the app next writes one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let lineNumber = try container.decode(String.self, forKey: .lineNumber)
        let lineColors = try container.decodeIfPresent(TrainLineColors.self, forKey: .lineColors)
        let departureTime = try container.decode(Date.self, forKey: .departureTime)
        let arrivalTime = try container.decode(Date.self, forKey: .arrivalTime)
        let destination = try container.decode(String.self, forKey: .destination)
        let platform = try container.decodeIfPresent(String.self, forKey: .platform)
        let transfers = try container.decodeIfPresent(Int.self, forKey: .transfers)
        let delay = try container.decode(Int.self, forKey: .delay)
        let stopCount = try container.decodeIfPresent(Int.self, forKey: .stopCount)
        let hasReminder = try container.decodeIfPresent(Bool.self, forKey: .hasReminder) ?? false
        let isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let hasServiceAlert = try container.decodeIfPresent(Bool.self, forKey: .hasServiceAlert) ?? false
        let isCancelled = try container.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false

        self.init(
            id: id,
            lineNumber: lineNumber,
            lineColors: lineColors,
            departureTime: departureTime,
            arrivalTime: arrivalTime,
            destination: destination,
            platform: platform,
            transfers: transfers,
            delay: delay,
            stopCount: stopCount,
            hasReminder: hasReminder,
            isPinned: isPinned,
            hasServiceAlert: hasServiceAlert,
            isCancelled: isCancelled
        )
    }
}

// MARK: - AppGroupStorage

enum AppGroupStorage {
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

    enum SnapshotLoadResult {
        case snapshot(WidgetData)
        /// A snapshot exists but this build cannot read it (schema change).
        case unreadable
        case missing
    }

    static func loadPrimaryWidgetData(for type: TransportType) -> WidgetData? {
        if case let .snapshot(data) = loadPrimaryWidgetSnapshot(for: type) { return data }
        return nil
    }

    /// Distinguishes "no route configured yet" from "a snapshot is there but this
    /// build can't decode it" — previously both rendered as "set up your commute",
    /// which tells a configured user to redo setup they have already done.
    static func loadPrimaryWidgetSnapshot(for type: TransportType) -> SnapshotLoadResult {
        guard let defaults = sharedDefaults,
              let primary = defaults.data(forKey: primaryStorageKey(for: type))
        else { return .missing }

        guard let decoded = try? JSONDecoder().decode(WidgetData.self, from: primary) else { return .unreadable }
        return .snapshot(decoded)
    }

    static func isPrimaryWidgetSnapshotUnreadable(for type: TransportType) -> Bool {
        if case .unreadable = loadPrimaryWidgetSnapshot(for: type) { return true }
        return false
    }

    private static func primaryStorageKey(for type: TransportType) -> String {
        "\(widgetDataKey)_\(normalizedKeyComponent(type.rawValue))"
    }
}

// MARK: - WidgetRenderSnapshot

/// The minimal slice of `WidgetData` a single timeline entry needs to render.
///
/// Timeline entries are archived individually by WidgetKit, so embedding the full
/// snapshot (up to `WidgetSnapshotBuilder.maxStoredConnectionLimit` connections) in
/// every entry multiplied the serialized timeline size by the entry count. Each entry
/// only ever renders one connection, so it carries exactly that one.
struct WidgetRenderSnapshot: Codable, Sendable {
    let routeText: String
    let compactRouteText: String
    let state: WidgetDataState
    let stateMessage: String?
    let recoveryAction: WidgetRecoveryAction?
    let connection: WidgetConnection?
    let leaveTime: Date?

    var isFallback: Bool { state == .fallback }

    /// The connection to render, paired with its leave time, when one is scheduled.
    var scheduled: (connection: WidgetConnection, leaveTime: Date)? {
        guard let connection, let leaveTime else { return nil }
        return (connection, leaveTime)
    }

    var emptyHintText: String {
        if let stateMessage, !stateMessage.isEmpty { return stateMessage }
        switch state {
        case .fallback: return "Open the app to refresh."
        case .stale: return "Check again soon or update route."
        case .fresh: return "Tap to set up your commute"
        }
    }

    static let missingHintText = "Tap to set up your commute"
}

extension WidgetData {
    /// Resolves the connection active at `date` and projects this snapshot down to
    /// what a single timeline entry renders.
    func renderSnapshot(
        at date: Date,
        overridingState: WidgetDataState? = nil,
        message: String? = nil
    ) -> WidgetRenderSnapshot {
        let resolvedState = overridingState ?? state
        // A stale entry deliberately drops its connection so the view falls through
        // to the "refreshing" empty state rather than showing data we no longer trust.
        let active = resolvedState == .stale ? nil : connection(at: date)
        return WidgetRenderSnapshot(
            routeText: routeText,
            compactRouteText: compactRouteText,
            state: resolvedState,
            stateMessage: message ?? stateMessage,
            recoveryAction: recoveryAction,
            connection: active?.connection,
            leaveTime: active?.leaveTime
        )
    }
}
