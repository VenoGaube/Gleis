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
    let transportType: TransportType
    let connections: [WidgetConnection]
    let leaveTimes: [Date]
    let fromStationName: String?
    let toStationName: String?
    let updatedAt: Date
    let state: WidgetDataState
    let stateMessage: String?
    let recoveryAction: WidgetRecoveryAction?

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
                arrivalTime: Date().addingTimeInterval(2100), destination: "Destination", platform: "3", transfers: 0,
                delay: 0, stopCount: 5
            ),
        ],
        leaveTimes: [Date().addingTimeInterval(600)],
        updatedAt: Date(),
        state: .fresh
    )
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
        destination: String, platform: String?, transfers: Int?, delay: Int, stopCount: Int?,
        hasReminder: Bool = false, isPinned: Bool = false, hasServiceAlert: Bool = false
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

    // Primary widget snapshot used as the single source of truth for all widget families.
    static func savePrimaryWidgetData(for type: TransportType, data: WidgetData) {
        saveWidgetData(for: .default(for: type), data: data)
    }

    static func loadPrimaryWidgetData(for type: TransportType) -> WidgetData? {
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
