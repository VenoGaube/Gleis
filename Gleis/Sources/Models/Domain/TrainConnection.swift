import Foundation

// MARK: - TrainLineColors

struct TrainLineColors: Codable, Equatable, Hashable {
    let backgroundHex: String?
    let foregroundHex: String?
    let accentHex: String?

    init(backgroundHex: String? = nil, foregroundHex: String? = nil, accentHex: String? = nil) {
        self.backgroundHex = Self.normalize(hex: backgroundHex)
        self.foregroundHex = Self.normalize(hex: foregroundHex)
        self.accentHex = Self.normalize(hex: accentHex)
    }

    var isEmpty: Bool { backgroundHex == nil && foregroundHex == nil && accentHex == nil }

    private static func normalize(hex: String?) -> String? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8 else { return nil }
        let invalid = CharacterSet(charactersIn: "0123456789ABCDEFabcdef").inverted
        guard value.rangeOfCharacter(from: invalid) == nil else { return nil }
        return "#\(value.uppercased())"
    }
}

// MARK: - TrainType

struct TrainType: Codable, Hashable, Identifiable, Comparable {
    let id: String
    let shortName: String
    let displayName: String
    let colors: TrainLineColors?

    static let other = TrainType(id: "OTHER", shortName: "Other", displayName: "Other")
    static let s = TrainType(id: "S", shortName: "S", displayName: "S-Bahn")

    init(id: String, shortName: String? = nil, displayName: String? = nil, colors: TrainLineColors? = nil) {
        let normalizedId = Self.normalizeIdentifier(id)
        self.id = normalizedId
        self.shortName = Self.normalizedLabel(shortName) ?? normalizedId
        self.displayName = Self.normalizedLabel(displayName) ?? self.shortName
        self.colors = colors?.isEmpty == true ? nil : colors
    }

    static func == (lhs: TrainType, rhs: TrainType) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func < (lhs: TrainType, rhs: TrainType) -> Bool {
        if lhs.id == rhs.id { return false }
        if lhs.id == other.id { return false }
        if rhs.id == other.id { return true }
        return lhs.shortName.localizedStandardCompare(rhs.shortName) == .orderedAscending
    }

    func merged(with other: TrainType) -> TrainType {
        guard id == other.id else { return self }
        let mergedColors = colors ?? other.colors
        let mergedDisplayName = displayName == shortName ? other.displayName : displayName
        return TrainType(id: id, shortName: shortName, displayName: mergedDisplayName, colors: mergedColors)
    }

    /// Derive dynamic train type from API category data.
    static func from(category: OebbCategory?, fallbackLineNumber: String? = nil) -> TrainType {
        let identifier = trainTypeIdentifier(from: category, fallbackLineNumber: fallbackLineNumber) ?? other.id
        let display =
            normalizedLabel(category?.displayName)
            ?? normalizedLabel(category?.longName?["en"])
            ?? normalizedLabel(category?.longName?["de"])
            ?? normalizedLabel(category?.name)
            ?? identifier
        return TrainType(id: identifier, shortName: identifier, displayName: display, colors: category?.lineColors)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case shortName
        case displayName
        case colors
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self = Self.fromLegacy(raw)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId =
            (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .shortName))
            ?? (try? container.decode(String.self, forKey: .displayName))
            ?? Self.other.id
        let shortName = try? container.decode(String.self, forKey: .shortName)
        let displayName = try? container.decode(String.self, forKey: .displayName)
        let colors = try? container.decode(TrainLineColors.self, forKey: .colors)
        self.init(id: decodedId, shortName: shortName, displayName: displayName, colors: colors)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shortName, forKey: .shortName)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(colors, forKey: .colors)
    }

    private static func fromLegacy(_ rawValue: String) -> TrainType {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "rj": return TrainType(id: "RJ", shortName: "RJ", displayName: "Railjet")
        case "rjx": return TrainType(id: "RJX", shortName: "RJX", displayName: "Railjet Xpress")
        case "ice": return TrainType(id: "ICE", shortName: "ICE", displayName: "ICE")
        case "ic": return TrainType(id: "IC", shortName: "IC", displayName: "InterCity")
        case "ec", "ece": return TrainType(id: "EC", shortName: "EC", displayName: "EuroCity")
        case "en": return TrainType(id: "EN", shortName: "EN", displayName: "EuroNight")
        case "nj": return TrainType(id: "NJ", shortName: "NJ", displayName: "Nightjet")
        case "rex": return TrainType(id: "REX", shortName: "REX", displayName: "REX")
        case "r": return TrainType(id: "R", shortName: "R", displayName: "Regional")
        case "d": return TrainType(id: "D", shortName: "D", displayName: "D-Zug")
        case "s": return .s
        case "u": return TrainType(id: "U", shortName: "U", displayName: "U-Bahn")
        case "bus": return TrainType(id: "BUS", shortName: "BUS", displayName: "Bus")
        default:
            let normalized = normalizeIdentifier(rawValue)
            return normalized == other.id
                ? .other
                : TrainType(id: normalized, shortName: normalized, displayName: normalized)
        }
    }

    private static func trainTypeIdentifier(from category: OebbCategory?, fallbackLineNumber: String?) -> String? {
        let candidates = [
            category?.shortName,
            category?.displayName,
            category?.name,
            category?.number,
            fallbackLineNumber,
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            if let identifier = extractIdentifier(from: candidate) { return identifier }
        }
        return nil
    }

    private static func extractIdentifier(from value: String) -> String? {
        let upper = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return nil }

        let tokens = upper.split(whereSeparator: \.isWhitespace).map(String.init)
        for token in tokens {
            let cleaned = token.filter { $0.isLetter || $0.isNumber }
            guard !cleaned.isEmpty else { continue }
            if let letters = leadingLetters(in: cleaned) {
                return normalizeIdentifier(letters)
            }
            if cleaned.allSatisfy(\.isLetter) {
                return normalizeIdentifier(cleaned)
            }
        }

        return nil
    }

    private static func leadingLetters(in value: String) -> String? {
        let prefix = value.prefix { $0.isLetter }
        guard !prefix.isEmpty else { return nil }
        return String(prefix)
    }

    private static func normalizeIdentifier(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().filter {
            $0.isLetter || $0.isNumber
        }
        return cleaned.isEmpty ? other.id : cleaned
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - TrainConnection

struct TrainConnection: Identifiable, Codable, Equatable {
    let id: String
    let lineNumber: String
    let trainType: TrainType
    let lineColors: TrainLineColors?
    let departureTime: Date
    let arrivalTime: Date
    let departureStation: Station
    let arrivalStation: Station
    let platform: String?
    let delay: Int
    let status: ConnectionStatus
    let transfers: Int
    let legs: [ConnectionLeg]
    var serviceAlerts: [ServiceAlert]? = nil

    var isDelayed: Bool { delay > 0 }
    var duration: TimeInterval { max(0, arrivalTime.timeIntervalSince(departureTime)) }
    var hasServiceAlerts: Bool { !(serviceAlerts ?? []).isEmpty }

    var totalStopCount: Int? {
        let counts = legs.filter { !$0.isWalking }.compactMap { leg in
            if let stopCount = leg.stopCount { return stopCount }
            return leg.intermediateStops.isEmpty ? nil : leg.intermediateStops.count
        }
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }
}

struct ServiceAlert: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let message: String
    let startsAt: Date?
    let endsAt: Date?
    let priority: Int
    let isActive: Bool
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

}

// MARK: - ConnectionLeg

struct ConnectionLeg: Identifiable, Codable, Equatable {
    let id: UUID
    let from: Station
    let to: Station
    let departureTime: Date?
    let arrivalTime: Date?
    /// Departure platform for this leg.
    let platform: String?
    /// Arrival platform for this leg.
    let arrivalPlatform: String?
    let lineNumber: String
    let trainType: TrainType
    let lineColors: TrainLineColors?
    let isWalking: Bool
    let duration: TimeInterval?
    let finalDestination: String?
    let platformChanged: Bool
    let stopCount: Int?
    let delayMinutes: Int?
    let departureDelayMinutes: Int?
    let arrivalDelayMinutes: Int?
    let intermediateStops: [IntermediateStop]

    init(
        id: UUID = UUID(), from: Station, to: Station, departureTime: Date?, arrivalTime: Date?, platform: String?,
        arrivalPlatform: String? = nil,
        lineNumber: String, trainType: TrainType = .other, lineColors: TrainLineColors? = nil, isWalking: Bool,
        duration: TimeInterval?,
        finalDestination: String? = nil, platformChanged: Bool = false, stopCount: Int? = nil,
        delayMinutes: Int? = nil, departureDelayMinutes: Int? = nil, arrivalDelayMinutes: Int? = nil,
        intermediateStops: [IntermediateStop] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.platform = platform
        self.arrivalPlatform = arrivalPlatform
        self.lineNumber = lineNumber
        self.trainType = trainType
        self.lineColors = lineColors
        self.isWalking = isWalking
        self.duration = duration
        self.finalDestination = finalDestination
        self.platformChanged = platformChanged
        self.stopCount = stopCount
        self.delayMinutes = delayMinutes
        self.departureDelayMinutes = departureDelayMinutes
        self.arrivalDelayMinutes = arrivalDelayMinutes
        self.intermediateStops = intermediateStops
    }
}

// MARK: - ConnectionTransferPlanner

struct ConnectionTransferPlanner {
    struct Context {
        let nextLeg: ConnectionLeg
        let targetLeg: ConnectionLeg
        let walkingLegs: [ConnectionLeg]
        let nextLegIsWalking: Bool

        var hasUpcomingTransitLeg: Bool { !targetLeg.isWalking }
        var involvesWalking: Bool { !walkingLegs.isEmpty }
    }

    static func context(after index: Int, legs: [ConnectionLeg]) -> Context? {
        guard index >= 0, index + 1 < legs.count else { return nil }

        let nextLeg = legs[index + 1]
        let walkingStartIndex = legs[index].isWalking ? index : index + 1
        let walkingLegs = consecutiveWalkingLegs(startingAt: walkingStartIndex, in: legs)

        var targetIndex = index + 1
        while targetIndex < legs.count, legs[targetIndex].isWalking {
            targetIndex += 1
        }

        let targetLeg = targetIndex < legs.count ? legs[targetIndex] : legs[legs.count - 1]
        return Context(nextLeg: nextLeg, targetLeg: targetLeg, walkingLegs: walkingLegs, nextLegIsWalking: nextLeg.isWalking)
    }

    static func transferMinutes(from currentLeg: ConnectionLeg, to targetLeg: ConnectionLeg) -> Int? {
        guard let arrival = currentLeg.arrivalTime, let departure = targetLeg.departureTime else { return nil }
        return max(0, Int(departure.timeIntervalSince(arrival) / 60))
    }

    static func plannedTime(from time: Date?, delayMinutes: Int?) -> Date? {
        guard let time else { return nil }
        let delay = max(0, delayMinutes ?? 0)
        guard delay > 0 else { return time }
        return time.addingTimeInterval(TimeInterval(-delay * 60))
    }

    static func walkingDurationMinutes(for leg: ConnectionLeg) -> Int? {
        guard leg.isWalking else { return nil }
        if let duration = leg.duration {
            return max(1, Int(ceil(duration / 60)))
        }
        guard let departure = leg.departureTime, let arrival = leg.arrivalTime else { return nil }
        return max(1, Int(ceil(arrival.timeIntervalSince(departure) / 60)))
    }

    private static func consecutiveWalkingLegs(startingAt index: Int, in legs: [ConnectionLeg]) -> [ConnectionLeg] {
        guard index >= 0, index < legs.count else { return [] }
        var result: [ConnectionLeg] = []
        var currentIndex = index

        while currentIndex < legs.count, legs[currentIndex].isWalking {
            result.append(legs[currentIndex])
            currentIndex += 1
        }

        return result
    }
}
