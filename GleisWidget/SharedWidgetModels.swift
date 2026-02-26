import Foundation

// MARK: - TransportType

enum TransportType: String, Codable { case trainCommute = "Train" }

// MARK: - TrainLineColors

struct TrainLineColors: Codable, Equatable, Hashable {
    let backgroundHex: String?
    let foregroundHex: String?
    let accentHex: String?
}

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
    let transportType: TransportType
    let connections: [WidgetConnection]
    let leaveTimes: [Date]
    let fromStationName: String?
    let toStationName: String?
    let updatedAt: Date
    let state: WidgetDataState
    let stateMessage: String?
    let recoveryAction: WidgetRecoveryAction?

    // Backwards compatibility
    var nextConnection: WidgetConnection? { connections.first }
    var leaveTime: Date? { leaveTimes.first }

    init(
        transportType: TransportType,
        connections: [WidgetConnection],
        leaveTimes: [Date],
        fromStationName: String? = nil,
        toStationName: String? = nil,
        updatedAt: Date,
        state: WidgetDataState = .fresh,
        stateMessage: String? = nil,
        recoveryAction: WidgetRecoveryAction? = nil
    ) {
        self.transportType = transportType
        self.connections = connections
        self.leaveTimes = leaveTimes
        self.fromStationName = fromStationName
        self.toStationName = toStationName
        self.updatedAt = updatedAt
        self.state = state
        self.stateMessage = stateMessage
        self.recoveryAction = recoveryAction
    }

    private enum CodingKeys: String, CodingKey {
        case transportType
        case connections
        case leaveTimes
        case fromStationName
        case toStationName
        case updatedAt
        case state
        case stateMessage
        case recoveryAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transportType = try container.decode(TransportType.self, forKey: .transportType)
        connections = try container.decode([WidgetConnection].self, forKey: .connections)
        leaveTimes = try container.decode([Date].self, forKey: .leaveTimes)
        fromStationName = try container.decodeIfPresent(String.self, forKey: .fromStationName)
        toStationName = try container.decodeIfPresent(String.self, forKey: .toStationName)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        state = try container.decodeIfPresent(WidgetDataState.self, forKey: .state) ?? .fresh
        stateMessage = try container.decodeIfPresent(String.self, forKey: .stateMessage)
        recoveryAction = try container.decodeIfPresent(WidgetRecoveryAction.self, forKey: .recoveryAction)
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

    static let delayedPlaceholder = WidgetData(
        transportType: .trainCommute,
        connections: [
            WidgetConnection(
                id: "delayed", lineNumber: "REX3", departureTime: Date().addingTimeInterval(1200),
                arrivalTime: Date().addingTimeInterval(3000), destination: "Bratislava hl.st.", platform: "7",
                transfers: 0, delay: 5, stopCount: 8, hasReminder: false, isPinned: false
            ),
        ],
        leaveTimes: [Date().addingTimeInterval(900)],
        updatedAt: Date(),
        state: .fresh
    )

    private var scheduledConnections: [(connection: WidgetConnection, leaveTime: Date)] {
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

        // Find the next regular (non-pinned) connection by leave time
        var nextRegular: (connection: WidgetConnection, leaveTime: Date)?
        for item in scheduled where date < item.leaveTime && !item.connection.isPinned {
            nextRegular = item
            break
        }

        // Priority 1: Show pinned "My Journey" only if:
        // - Its departure time hasn't passed, AND
        // - Its leave time is within 20 minutes of the next regular connection (or no regular connection exists)
        for item in scheduled where item.connection.isPinned && item.connection.departureTime > date {
            let pinnedLeaveTime = item.leaveTime

            // If pinned leave time has passed, show it (it's time!)
            if pinnedLeaveTime <= date { return (item.connection, pinnedLeaveTime) }

            // If no regular connection, show pinned
            guard let regular = nextRegular else { return (item.connection, pinnedLeaveTime) }

            let timeDifference = abs(pinnedLeaveTime.timeIntervalSince(regular.leaveTime))

            // Only prioritize pinned if within 20 minutes of next regular connection
            if timeDifference <= 20 * 60 { return (item.connection, pinnedLeaveTime) }
            // Otherwise, don't prioritize pinned yet - fall through to regular logic
        }

        // Priority 2: Show reminder-set connection until its departure (pinned until GO! completes)
        for item in scheduled where item.connection.hasReminder && item.connection.departureTime > date {
            return item
        }

        // Priority 3: Find first connection whose leave time hasn't passed
        for item in scheduled where date < item.leaveTime {
            return item
        }

        // Priority 4: Show in-flight train if departure already happened but no next leave yet.
        if let inFlight = scheduled.first(where: { $0.leaveTime <= date && $0.connection.departureTime > date }) {
            return inFlight
        }
        return nil
    }

    /// Check if the data is stale (all connections have departed or data is too old)
    var isStale: Bool {
        if state == .stale { return true }
        let now = Date()
        // Data is stale if updated more than 6 hours ago
        if now.timeIntervalSince(updatedAt) > 6 * 60 * 60 { return true }
        // Data is stale if all connections have departed
        guard let lastDeparture = connections.map(\.departureTime).max() else { return true }
        return lastDeparture < now
    }

    var isFallback: Bool { state == .fallback }

    /// Returns connections that haven't departed yet
    func futureConnections(from date: Date) -> [(connection: WidgetConnection, leaveTime: Date)] {
        var result: [(connection: WidgetConnection, leaveTime: Date)] = []
        for item in scheduledConnections {
            // Include if departure is in the future OR if leave time hasn't passed yet
            if item.connection.departureTime > date || item.leaveTime > date { result.append(item) }
        }
        return result
    }
}

// MARK: - WidgetDataStorageKey

enum WidgetRouteScope: String, Codable {
    case liveRoute
    case repeatJourney
}

enum WidgetDirectionScope: String, Codable {
    case forward
    case reverse
}

enum WidgetDayScope: String, Codable {
    case today
    case tomorrow
}

struct WidgetDataStorageKey: Codable, Hashable {
    let transportType: TransportType
    let routeScope: WidgetRouteScope
    let directionScope: WidgetDirectionScope
    let dayScope: WidgetDayScope

    var storageSuffix: String {
        [
            AppGroupStorage.normalizedKeyComponent(transportType.rawValue),
            routeScope.rawValue,
            directionScope.rawValue,
            dayScope.rawValue,
        ].joined(separator: "_")
    }

    var isDefaultKey: Bool {
        routeScope == .liveRoute && directionScope == .forward && dayScope == .today
    }

    static func `default`(for type: TransportType) -> WidgetDataStorageKey {
        WidgetDataStorageKey(
            transportType: type,
            routeScope: .liveRoute,
            directionScope: .forward,
            dayScope: .today
        )
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
        id: String, lineNumber: String, lineColors: TrainLineColors? = nil, departureTime: Date, arrivalTime: Date,
        destination: String, platform: String?, transfers: Int?, delay: Int, stopCount: Int?, hasReminder: Bool,
        isPinned: Bool, hasServiceAlert: Bool = false
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

    private enum CodingKeys: String, CodingKey {
        case id
        case lineNumber
        case lineColors
        case departureTime
        case arrivalTime
        case destination
        case platform
        case transfers
        case delay
        case stopCount
        case hasReminder
        case isPinned
        case hasServiceAlert
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        lineNumber = try container.decode(String.self, forKey: .lineNumber)
        lineColors = try container.decodeIfPresent(TrainLineColors.self, forKey: .lineColors)
        departureTime = try container.decode(Date.self, forKey: .departureTime)
        arrivalTime = try container.decode(Date.self, forKey: .arrivalTime)
        destination = try container.decode(String.self, forKey: .destination)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        transfers = try container.decodeIfPresent(Int.self, forKey: .transfers)
        delay = try container.decode(Int.self, forKey: .delay)
        stopCount = try container.decodeIfPresent(Int.self, forKey: .stopCount)
        hasReminder = try container.decodeIfPresent(Bool.self, forKey: .hasReminder) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        hasServiceAlert = try container.decodeIfPresent(Bool.self, forKey: .hasServiceAlert) ?? false
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

    static func saveWidgetData(for key: WidgetDataStorageKey, data: WidgetData) {
        guard let defaults = sharedDefaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: "\(widgetDataKey)_\(key.storageSuffix)")
    }

    static func loadWidgetData(for key: WidgetDataStorageKey) -> WidgetData? {
        guard let defaults = sharedDefaults else { return nil }
        if let data = defaults.data(forKey: "\(widgetDataKey)_\(key.storageSuffix)"),
           let decoded = try? JSONDecoder().decode(WidgetData.self, from: data)
        {
            return decoded
        }

        // Legacy fallback from pre-intent-keyed storage only for default key to
        // avoid showing forward-route data in reverse/day-specific widgets.
        guard key.isDefaultKey else { return nil }
        let legacyKey = "\(widgetDataKey)_\(key.transportType.rawValue)"
        guard let legacyData = defaults.data(forKey: legacyKey) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: legacyData)
    }

    static func saveWidgetData(for type: TransportType, data: WidgetData) {
        saveWidgetData(for: .default(for: type), data: data)
    }

    static func loadWidgetData(for type: TransportType) -> WidgetData? {
        loadWidgetData(for: .default(for: type))
    }

    static func markWidgetDataAsFallback(for key: WidgetDataStorageKey, message: String, updatedAt: Date = Date()) {
        guard var existing = loadWidgetData(for: key) else { return }
        existing = WidgetData(
            transportType: existing.transportType,
            connections: existing.connections,
            leaveTimes: existing.leaveTimes,
            fromStationName: existing.fromStationName,
            toStationName: existing.toStationName,
            updatedAt: updatedAt,
            state: .fallback,
            stateMessage: message,
            recoveryAction: existing.recoveryAction
        )
        saveWidgetData(for: key, data: existing)
    }
}
