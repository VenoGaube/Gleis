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
        hasReminder: Bool,
        isPinned: Bool,
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
