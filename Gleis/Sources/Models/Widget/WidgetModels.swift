import Foundation

// MARK: - WidgetData

struct WidgetData: Codable {
    let transportType: TransportType
    let connections: [WidgetConnection]
    let leaveTimes: [Date]
    let updatedAt: Date

    var nextConnection: WidgetConnection? { connections.first }
    var leaveTime: Date? { leaveTimes.first }

    static let placeholder = WidgetData(
        transportType: .trainCommute,
        connections: [
            WidgetConnection(
                id: "placeholder", lineNumber: "S1", departureTime: Date().addingTimeInterval(900),
                arrivalTime: Date().addingTimeInterval(2100), destination: "Destination", platform: "3", transfers: 0,
                delay: 0, stopCount: 5
            ),
        ], leaveTimes: [Date().addingTimeInterval(600)], updatedAt: Date()
    )
}

// MARK: - WidgetConnection

struct WidgetConnection: Codable {
    let id: String
    let lineNumber: String
    let departureTime: Date
    let arrivalTime: Date
    let destination: String
    let platform: String?
    let transfers: Int?
    let delay: Int
    let stopCount: Int?
    let hasReminder: Bool
    let isPinned: Bool

    var isDelayed: Bool { delay > 0 }

    init(
        id: String, lineNumber: String, departureTime: Date, arrivalTime: Date, destination: String, platform: String?,
        transfers: Int?, delay: Int, stopCount: Int?, hasReminder: Bool = false, isPinned: Bool = false
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.destination = destination
        self.platform = platform
        self.transfers = transfers
        self.delay = delay
        self.stopCount = stopCount
        self.hasReminder = hasReminder
        self.isPinned = isPinned
    }
}

// MARK: - AppGroupStorage

enum AppGroupStorage {
    static let suiteName = "group.com.veno.gleis.shared"
    static let widgetDataKey = "widgetData"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func saveWidgetData(_ data: WidgetData) {
        guard let defaults = sharedDefaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: widgetDataKey)
    }

    static func loadWidgetData() -> WidgetData? {
        guard let defaults = sharedDefaults, let data = defaults.data(forKey: widgetDataKey) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    static func saveWidgetData(for type: TransportType, data: WidgetData) {
        guard let defaults = sharedDefaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: "\(widgetDataKey)_\(type.rawValue)")
    }

    static func loadWidgetData(for type: TransportType) -> WidgetData? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: "\(widgetDataKey)_\(type.rawValue)") else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }
}
