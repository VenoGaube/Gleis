import Foundation

// MARK: - TrainType

enum TrainType: String, Codable, CaseIterable, Identifiable, Comparable {
    case rj, rjx, ice, ic, ec, en, nj // Long-distance
    case rex, r, d // Regional
    case s // S-Bahn
    case u // U-Bahn
    case bus
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rj: "Railjet"
        case .rjx: "Railjet Xpress"
        case .ice: "ICE"
        case .ic: "InterCity"
        case .ec: "EuroCity"
        case .en: "EuroNight"
        case .nj: "Nightjet"
        case .rex: "REX"
        case .r: "Regional"
        case .d: "D-Zug"
        case .s: "S-Bahn"
        case .u: "U-Bahn"
        case .bus: "Bus"
        case .other: "Other"
        }
    }

    var shortName: String {
        switch self {
        case .rj: "RJ"
        case .rjx: "RJX"
        case .ice: "ICE"
        case .ic: "IC"
        case .ec: "EC"
        case .en: "EN"
        case .nj: "NJ"
        case .rex: "REX"
        case .r: "R"
        case .d: "D"
        case .s: "S"
        case .u: "U"
        case .bus: "Bus"
        case .other: "?"
        }
    }

    /// Derive TrainType from an OebbCategory's short name / display name
    static func from(category: String?) -> TrainType {
        guard let raw = category?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return .other }
        switch raw {
        case "RJX": return .rjx
        case "RJ": return .rj
        case "ICE": return .ice
        case "IC": return .ic
        case "EC", "ECE": return .ec
        case "EN": return .en
        case "NJ": return .nj
        case "REX": return .rex
        case "R": return .r
        case "D": return .d
        case "S": return .s
        case "U": return .u
        case "BUS": return .bus
        default:
            if raw.hasPrefix("S") && raw.dropFirst().allSatisfy(\.isNumber) { return .s }
            if raw.hasPrefix("U") && raw.dropFirst().allSatisfy(\.isNumber) { return .u }
            if raw.hasPrefix("RJ") { return .rj }
            return .other
        }
    }

    static func < (lhs: TrainType, rhs: TrainType) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .rjx: 0
        case .rj: 1
        case .ice: 2
        case .ic: 3
        case .ec: 4
        case .en: 5
        case .nj: 6
        case .rex: 7
        case .r: 8
        case .d: 9
        case .s: 10
        case .u: 11
        case .bus: 12
        case .other: 13
        }
    }
}

// MARK: - TrainConnection

struct TrainConnection: Identifiable, Codable, Equatable {
    let id: String
    let lineNumber: String
    let trainType: TrainType
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
    let trainType: TrainType
    let isWalking: Bool
    let duration: TimeInterval?
    let finalDestination: String?
    let platformChanged: Bool
    let stopCount: Int?
    let delayMinutes: Int?
    let intermediateStops: [IntermediateStop]

    init(
        id: UUID = UUID(), from: Station, to: Station, departureTime: Date?, arrivalTime: Date?, platform: String?,
        lineNumber: String, trainType: TrainType = .other, isWalking: Bool, duration: TimeInterval?,
        finalDestination: String? = nil, platformChanged: Bool = false, stopCount: Int? = nil,
        delayMinutes: Int? = nil, intermediateStops: [IntermediateStop] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.platform = platform
        self.lineNumber = lineNumber
        self.trainType = trainType
        self.isWalking = isWalking
        self.duration = duration
        self.finalDestination = finalDestination
        self.platformChanged = platformChanged
        self.stopCount = stopCount
        self.delayMinutes = delayMinutes
        self.intermediateStops = intermediateStops
    }
}
