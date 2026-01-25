import Foundation

// MARK: - TrainConnection

struct TrainConnection: Identifiable, Codable, Equatable {
    let id: String
    let lineNumber: String
    let departureTime: Date
    let arrivalTime: Date
    let departureStation: Station
    let arrivalStation: Station
    let platform: String?
    let delay: Int
    let status: ConnectionStatus
    let transfers: Int
    let legs: [ConnectionLeg]

    var isDelayed: Bool { delay > 0 }
    var duration: TimeInterval { arrivalTime.timeIntervalSince(departureTime) }

    var totalStopCount: Int? {
        let counts = legs.filter { !$0.isWalking }.compactMap(\.stopCount)
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }
}

// MARK: - ConnectionStatus

enum ConnectionStatus: String, Codable {
    case onTime = "On Time"
    case delayed = "Delayed"
    case cancelled = "Cancelled"
    case unknown = "Unknown"
}

// MARK: - IntermediateStop

/// Represents an intermediate stop along a journey leg
struct IntermediateStop: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let arrivalTime: Date?
    let departureTime: Date?
    let arrivalDelay: Int?
    let departureDelay: Int?
    let platform: String?

    /// Returns the actual arrival time including delay
    var actualArrivalTime: Date? {
        guard let arrival = arrivalTime, let delay = arrivalDelay, delay > 0 else { return arrivalTime }
        return arrival.addingTimeInterval(TimeInterval(delay * 60))
    }
}

// MARK: - ConnectionLeg

struct ConnectionLeg: Identifiable, Codable, Equatable {
    let id: UUID
    let from: Station
    let to: Station
    let departureTime: Date?
    let arrivalTime: Date?
    let platform: String?
    let lineNumber: String
    let isWalking: Bool
    let duration: TimeInterval?
    let finalDestination: String?
    let platformChanged: Bool
    let stopCount: Int?
    let delayMinutes: Int?
    let intermediateStops: [IntermediateStop]

    init(
        id: UUID = UUID(),
        from: Station,
        to: Station,
        departureTime: Date?,
        arrivalTime: Date?,
        platform: String?,
        lineNumber: String,
        isWalking: Bool,
        duration: TimeInterval?,
        finalDestination: String? = nil,
        platformChanged: Bool = false,
        stopCount: Int? = nil,
        delayMinutes: Int? = nil,
        intermediateStops: [IntermediateStop] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.platform = platform
        self.lineNumber = lineNumber
        self.isWalking = isWalking
        self.duration = duration
        self.finalDestination = finalDestination
        self.platformChanged = platformChanged
        self.stopCount = stopCount
        self.delayMinutes = delayMinutes
        self.intermediateStops = intermediateStops
    }
}
