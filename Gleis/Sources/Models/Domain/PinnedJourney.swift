import Foundation

struct PinnedJourney: Codable, Equatable {
    let connectionId: String
    let lineNumber: String
    let lineColors: TrainLineColors?
    let departureTime: Date
    let arrivalTime: Date
    let departureStation: Station
    let arrivalStation: Station
    let platform: String?
    let delay: Int
    let pinnedAt: Date
    let legs: [ConnectionLeg]
    let transfers: Int

    /// Checks if the journey should be auto-unpinned based on arrival time
    func shouldAutoUnpin(currentDate: Date = Date()) -> Bool { currentDate >= arrivalTime }

    /// Returns whether the journey has departed but not yet arrived
    var isInProgress: Bool {
        let now = Date()
        return now >= departureTime && now < arrivalTime
    }

    /// Returns whether the journey has departed
    var hasDeparted: Bool { Date() >= departureTime }

    /// All intermediate stops across all legs
    var allIntermediateStops: [IntermediateStop] { legs.filter { !$0.isWalking }.flatMap(\.intermediateStops) }

    /// Creates a PinnedJourney from a TrainConnection
    init(from connection: TrainConnection) {
        connectionId = connection.id
        lineNumber = connection.lineNumber
        lineColors = connection.lineColors
        departureTime = connection.departureTime
        arrivalTime = connection.arrivalTime
        departureStation = connection.departureStation
        arrivalStation = connection.arrivalStation
        platform = connection.platform
        delay = connection.delay
        pinnedAt = Date()
        legs = connection.legs
        transfers = connection.transfers
    }

    /// Manual initializer for full control (useful for testing)
    init(
        connectionId: String, lineNumber: String, departureTime: Date, arrivalTime: Date, departureStation: Station,
        arrivalStation: Station, platform: String?, delay: Int, pinnedAt: Date, legs: [ConnectionLeg] = [],
        transfers: Int = 0, lineColors: TrainLineColors? = nil
    ) {
        self.connectionId = connectionId
        self.lineNumber = lineNumber
        self.lineColors = lineColors
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.departureStation = departureStation
        self.arrivalStation = arrivalStation
        self.platform = platform
        self.delay = delay
        self.pinnedAt = pinnedAt
        self.legs = legs
        self.transfers = transfers
    }
}
