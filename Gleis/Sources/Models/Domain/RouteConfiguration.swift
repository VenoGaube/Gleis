import Foundation

// MARK: - RouteConfiguration

struct RouteConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var startStation: Station?
    var endStation: Station?
    var walkingTimeMinutes: Int
    var bufferTimeMinutes: Int
    var useDelayInLeaveTime: Bool?
    var maxConnections: Int?
    var notificationSettings: NotificationSettings
    var activeDays: Set<Weekday>
    var recentStations: [Station]
    var favoriteStations: [Station]
    var stationTravelTimes: [String: Int]
    var stationBufferTimes: [String: Int]
    var excludedTrainTypes: Set<TrainType>

    init() {
        id = UUID()
        walkingTimeMinutes = 0
        bufferTimeMinutes = 0
        useDelayInLeaveTime = false
        maxConnections = 25
        notificationSettings = NotificationSettings()
        activeDays = Set(Weekday.allCases)
        recentStations = []
        favoriteStations = []
        stationTravelTimes = [:]
        stationBufferTimes = [:]
        excludedTrainTypes = []
    }

    func travelTime(for stationId: String?) -> Int? {
        guard let id = stationId else { return nil }
        return stationTravelTimes[id]
    }

    mutating func setTravelTime(_ minutes: Int?, for stationId: String) {
        if let minutes {
            stationTravelTimes[stationId] = minutes
        } else {
            stationTravelTimes.removeValue(forKey: stationId)
        }
    }

    func bufferTime(for stationId: String?) -> Int? {
        guard let id = stationId else { return nil }
        return stationBufferTimes[id]
    }

    mutating func setBufferTime(_ minutes: Int?, for stationId: String) {
        if let minutes {
            stationBufferTimes[stationId] = minutes
        } else {
            stationBufferTimes.removeValue(forKey: stationId)
        }
    }

    var displayMaxConnections: Int { maxConnections ?? 25 }
    var usesDelayInLeaveTime: Bool { useDelayInLeaveTime ?? false }

    func effectiveDepartureTime(for connection: TrainConnection) -> Date {
        effectiveDepartureTime(
            baseDepartureTime: connection.departureTime,
            delayMinutes: connection.delay,
            realtimeDepartureHint: connection.legs.first(where: { !$0.isWalking })?.departureTime
        )
    }

    func effectiveDepartureTime(
        baseDepartureTime: Date,
        delayMinutes: Int,
        realtimeDepartureHint: Date?
    ) -> Date {
        guard usesDelayInLeaveTime, delayMinutes > 0 else { return baseDepartureTime }

        // If departure is already realtime, delay has already been applied.
        if let realtimeDepartureHint,
           abs(realtimeDepartureHint.timeIntervalSince(baseDepartureTime)) < 30
        {
            return baseDepartureTime
        }

        return baseDepartureTime.addingTimeInterval(TimeInterval(delayMinutes * 60))
    }

    /// Calculates leave time using station-specific travel time and buffer time.
    /// Falls back to general walking/buffer times if station-specific times aren't configured.
    func leaveTime(for connection: TrainConnection, fromStationId: String?) -> Date {
        let travel = travelTime(for: fromStationId) ?? walkingTimeMinutes
        let buffer = bufferTime(for: fromStationId) ?? bufferTimeMinutes
        return effectiveDepartureTime(for: connection).addingTimeInterval(-TimeInterval((travel + buffer) * 60))
    }

    mutating func addRecentStation(_ station: Station) {
        recentStations.removeAll { $0.id == station.id }
        recentStations.insert(station, at: 0)
        if recentStations.count > 5 { recentStations.removeLast() }
    }

    func isFavoriteStation(_ station: Station) -> Bool { favoriteStations.contains { $0.id == station.id } }

    mutating func toggleFavoriteStation(_ station: Station) {
        if isFavoriteStation(station) {
            favoriteStations.removeAll { $0.id == station.id }
        } else {
            favoriteStations.insert(station, at: 0)
        }
    }
}

// MARK: - NotificationSettings

struct NotificationSettings: Codable, Equatable {
    var customMessage: String
    var soundEnabled: Bool

    init() {
        soundEnabled = true
        customMessage = "🚂 Time to catch your train!"
    }
}

// MARK: - Weekday

enum Weekday: Int, CaseIterable, Codable, Identifiable {
    case sunday = 1
    case monday, tuesday, wednesday, thursday, friday, saturday

    var id: Int { rawValue }
    var isWeekend: Bool { self == .saturday || self == .sunday }
    var shortName: String { ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"][rawValue - 1] }

    var fullName: String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][rawValue - 1]
    }

    /// Returns weekdays in Monday-first order for UI display
    static var mondayFirst: [Weekday] { [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday] }
    static var workweek: [Weekday] { [.monday, .tuesday, .wednesday, .thursday, .friday] }
    static var weekend: [Weekday] { [.saturday, .sunday] }

    /// The next calendar date that falls on this weekday, today included.
    ///
    /// Timetables differ by day of week, so anything searching on a day's behalf has
    /// to search that day — seeding from "today" showed a Thursday timetable while the
    /// user was configuring Monday.
    func nextOccurrence(after reference: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfReference = calendar.startOfDay(for: reference)
        let referenceWeekday = calendar.component(.weekday, from: startOfReference)
        let offset = (rawValue - referenceWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: startOfReference) ?? startOfReference
    }
}

extension RouteConfiguration {
    /// Decodes field by field so one unreadable or newly added field does not reset the whole route.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        startStation = try? container.decodeIfPresent(Station.self, forKey: .startStation)
        endStation = try? container.decodeIfPresent(Station.self, forKey: .endStation)
        walkingTimeMinutes = (try? container.decode(Int.self, forKey: .walkingTimeMinutes)) ?? 0
        bufferTimeMinutes = (try? container.decode(Int.self, forKey: .bufferTimeMinutes)) ?? 0
        useDelayInLeaveTime = try? container.decodeIfPresent(Bool.self, forKey: .useDelayInLeaveTime)
        maxConnections = try? container.decodeIfPresent(Int.self, forKey: .maxConnections)
        notificationSettings =
            (try? container.decode(NotificationSettings.self, forKey: .notificationSettings)) ?? NotificationSettings()
        activeDays = (try? container.decode(Set<Weekday>.self, forKey: .activeDays)) ?? Set(Weekday.allCases)
        recentStations = (try? container.decode([Station].self, forKey: .recentStations)) ?? []
        favoriteStations = (try? container.decode([Station].self, forKey: .favoriteStations)) ?? []
        stationTravelTimes = (try? container.decode([String: Int].self, forKey: .stationTravelTimes)) ?? [:]
        stationBufferTimes = (try? container.decode([String: Int].self, forKey: .stationBufferTimes)) ?? [:]
        excludedTrainTypes = (try? container.decode(Set<TrainType>.self, forKey: .excludedTrainTypes)) ?? []
    }
}
