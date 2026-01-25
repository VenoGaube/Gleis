import Foundation

// MARK: - TransportType

enum TransportType: String, Codable {
    case trainCommute = "Train"
}

// MARK: - WidgetData

struct WidgetData: Codable {
    let transportType: TransportType
    let connections: [WidgetConnection]
    let leaveTimes: [Date]
    let updatedAt: Date

    // Backwards compatibility
    var nextConnection: WidgetConnection? { connections.first }
    var leaveTime: Date? { leaveTimes.first }

    static let placeholder = WidgetData(
        transportType: .trainCommute,
        connections: [WidgetConnection(
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
        )],
        leaveTimes: [Date().addingTimeInterval(600)],
        updatedAt: Date()
    )

    static let delayedPlaceholder = WidgetData(
        transportType: .trainCommute,
        connections: [WidgetConnection(
            id: "delayed",
            lineNumber: "REX3",
            departureTime: Date().addingTimeInterval(1200),
            arrivalTime: Date().addingTimeInterval(3000),
            destination: "Bratislava hl.st.",
            platform: "7",
            transfers: 0,
            delay: 5,
            stopCount: 8,
            hasReminder: false,
            isPinned: false
        )],
        leaveTimes: [Date().addingTimeInterval(900)],
        updatedAt: Date()
    )

    func connection(at date: Date) -> (connection: WidgetConnection, leaveTime: Date)? {
        // Find the next regular (non-pinned) connection by leave time
        var nextRegularIndex: Int?
        for (i, lt) in leaveTimes.enumerated() where date < lt && !connections[i].isPinned {
            nextRegularIndex = i
            break
        }

        // Priority 1: Show pinned "My Journey" only if:
        // - Its arrival time hasn't passed, AND
        // - Its leave time is within 20 minutes of the next regular connection (or no regular connection exists)
        for (i, conn) in connections.enumerated() where conn.isPinned && conn.arrivalTime > date {
            let pinnedLeaveTime = leaveTimes[i]

            // If pinned leave time has passed, show it (it's time!)
            if pinnedLeaveTime <= date {
                return (conn, pinnedLeaveTime)
            }

            // If no regular connection, show pinned
            guard let regularIdx = nextRegularIndex else {
                return (conn, pinnedLeaveTime)
            }

            let regularLeaveTime = leaveTimes[regularIdx]
            let timeDifference = abs(pinnedLeaveTime.timeIntervalSince(regularLeaveTime))

            // Only prioritize pinned if within 20 minutes of next regular connection
            if timeDifference <= 20 * 60 {
                return (conn, pinnedLeaveTime)
            }
            // Otherwise, don't prioritize pinned yet - fall through to regular logic
        }

        // Priority 2: Show reminder-set connection until its departure (pinned until GO! completes)
        for (i, conn) in connections.enumerated() where conn.hasReminder && conn.departureTime > date {
            return (conn, leaveTimes[i])
        }

        // Priority 3: Find first connection whose leave time hasn't passed
        for (i, lt) in leaveTimes.enumerated() where date < lt {
            return (connections[i], lt)
        }

        // Priority 4: Show last connection if its departure hasn't passed (for GO! state)
        if let lastIndex = connections.indices.last, connections[lastIndex].departureTime > date {
            return (connections[lastIndex], leaveTimes[lastIndex])
        }
        return nil
    }

    /// Check if the data is stale (all connections have departed or data is too old)
    var isStale: Bool {
        let now = Date()
        // Data is stale if updated more than 6 hours ago
        if now.timeIntervalSince(updatedAt) > 6 * 60 * 60 {
            return true
        }
        // Data is stale if all connections have departed
        guard let lastConnection = connections.last else { return true }
        return lastConnection.departureTime < now
    }

    /// Returns connections that haven't departed yet
    func futureConnections(from date: Date) -> [(connection: WidgetConnection, leaveTime: Date)] {
        var result: [(WidgetConnection, Date)] = []
        for (i, conn) in connections.enumerated() {
            // Include if departure is in the future OR if leave time hasn't passed yet
            if conn.departureTime > date || leaveTimes[i] > date {
                result.append((conn, leaveTimes[i]))
            }
        }
        return result
    }
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
}

// MARK: - AppGroupStorage

enum AppGroupStorage {
    static let suiteName = "group.com.veno.gleis.shared"
    static let widgetDataKey = "widgetData"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func saveWidgetData(_ data: WidgetData) {
        guard let defaults = sharedDefaults,
              let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: widgetDataKey)
    }

    static func loadWidgetData() -> WidgetData? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: widgetDataKey),
              let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else { return nil }
        return decoded
    }

    static func saveWidgetData(for type: TransportType, data: WidgetData) {
        guard let defaults = sharedDefaults,
              let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: "\(widgetDataKey)_\(type.rawValue)")
    }

    static func loadWidgetData(for type: TransportType) -> WidgetData? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: "\(widgetDataKey)_\(type.rawValue)"),
              let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else { return nil }
        return decoded
    }
}
