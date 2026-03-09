import Foundation

// MARK: - SavedCommuteRoute

struct SavedCommuteRoute: Identifiable, Codable, Equatable {
    let id: UUID
    var homeStation: Station?
    var workStation: Station?
    var toWorkSchedules: [Weekday: DaySchedule]
    var toHomeSchedules: [Weekday: DaySchedule]
    var toWorkActiveDays: Set<Weekday>
    var toHomeActiveDays: Set<Weekday>
    var skippedDates: [Date]
    var skippedOccurrences: [SkippedCommuteOccurrence]

    private static let defaultWorkweekDays: Set<Weekday> = Set(Weekday.workweek)

    private enum CodingKeys: String, CodingKey {
        case id
        case homeStation
        case workStation
        case toWorkSchedules
        case toHomeSchedules
        case toWorkActiveDays
        case toHomeActiveDays
        case skippedDates
        case skippedOccurrences
    }

    init() {
        id = UUID()
        toWorkSchedules = [:]
        toHomeSchedules = [:]
        toWorkActiveDays = Self.defaultWorkweekDays
        toHomeActiveDays = Self.defaultWorkweekDays
        skippedDates = []
        skippedOccurrences = []
    }

    var isConfigured: Bool { homeStation != nil && workStation != nil }
    var scheduledDays: Set<Weekday> { Set(toWorkSchedules.keys).union(toHomeSchedules.keys) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        homeStation = try container.decodeIfPresent(Station.self, forKey: .homeStation)
        workStation = try container.decodeIfPresent(Station.self, forKey: .workStation)
        toWorkSchedules = try container.decodeIfPresent([Weekday: DaySchedule].self, forKey: .toWorkSchedules) ?? [:]
        toHomeSchedules = try container.decodeIfPresent([Weekday: DaySchedule].self, forKey: .toHomeSchedules) ?? [:]
        skippedDates = try container.decodeIfPresent([Date].self, forKey: .skippedDates) ?? []
        skippedOccurrences =
            try container.decodeIfPresent([SkippedCommuteOccurrence].self, forKey: .skippedOccurrences) ?? []

        let decodedToWorkActive =
            try container.decodeIfPresent(Set<Weekday>.self, forKey: .toWorkActiveDays)
            ?? Self.defaultWorkweekDays.union(toWorkSchedules.keys)
        let decodedToHomeActive =
            try container.decodeIfPresent(Set<Weekday>.self, forKey: .toHomeActiveDays)
            ?? Self.defaultWorkweekDays.union(toHomeSchedules.keys)

        toWorkActiveDays = Self.sanitizedActiveDays(decodedToWorkActive, scheduledDays: toWorkSchedules.keys)
        toHomeActiveDays = Self.sanitizedActiveDays(decodedToHomeActive, scheduledDays: toHomeSchedules.keys)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(homeStation, forKey: .homeStation)
        try container.encode(workStation, forKey: .workStation)
        try container.encode(toWorkSchedules, forKey: .toWorkSchedules)
        try container.encode(toHomeSchedules, forKey: .toHomeSchedules)
        try container.encode(toWorkActiveDays, forKey: .toWorkActiveDays)
        try container.encode(toHomeActiveDays, forKey: .toHomeActiveDays)
        try container.encode(skippedDates, forKey: .skippedDates)
        try container.encode(skippedOccurrences, forKey: .skippedOccurrences)
    }

    func schedule(for day: Weekday, direction: CommuteDirection = .toWork) -> DaySchedule? {
        direction == .toWork ? toWorkSchedules[day] : toHomeSchedules[day]
    }

    func activeDays(for direction: CommuteDirection) -> Set<Weekday> {
        direction == .toWork ? toWorkActiveDays : toHomeActiveDays
    }

    func isDayActive(_ day: Weekday, direction: CommuteDirection) -> Bool {
        activeDays(for: direction).contains(day)
    }

    func fromStation(for direction: CommuteDirection) -> Station? { direction == .toWork ? homeStation : workStation }

    func toStation(for direction: CommuteDirection) -> Station? { direction == .toWork ? workStation : homeStation }

    mutating func setSchedule(_ schedule: DaySchedule, for day: Weekday, direction: CommuteDirection) {
        if direction == .toWork {
            toWorkSchedules[day] = schedule
            toWorkActiveDays.insert(day)
        } else {
            toHomeSchedules[day] = schedule
            toHomeActiveDays.insert(day)
        }
    }

    mutating func removeSchedule(for day: Weekday, direction: CommuteDirection) {
        if direction == .toWork {
            toWorkSchedules.removeValue(forKey: day)
        } else {
            toHomeSchedules.removeValue(forKey: day)
        }
        skippedOccurrences.removeAll {
            $0.direction == direction
                && Calendar.current.component(.weekday, from: $0.date) == day.rawValue
        }
    }

    mutating func setActiveDays(_ days: Set<Weekday>, for direction: CommuteDirection) {
        let sanitized: Set<Weekday> = days.isEmpty ? Self.defaultWorkweekDays : days
        if direction == .toWork {
            toWorkActiveDays = sanitized.union(toWorkSchedules.keys)
        } else {
            toHomeActiveDays = sanitized.union(toHomeSchedules.keys)
        }
    }

    mutating func setDayActive(_ day: Weekday, isActive: Bool, direction: CommuteDirection) {
        var days = activeDays(for: direction)
        if isActive {
            days.insert(day)
        } else {
            let hasSchedule = schedule(for: day, direction: direction) != nil
            if hasSchedule || days.count <= 1 { return }
            days.remove(day)
        }
        setActiveDays(days, for: direction)
    }

    func matchesSchedule(_ connection: TrainConnection) -> CommuteDirection? {
        let calendar = Calendar.current
        guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: connection.departureTime)) else {
            return nil
        }

        let connHour = calendar.component(.hour, from: connection.departureTime)
        let connMinute = calendar.component(.minute, from: connection.departureTime)

        if isDayActive(weekday, direction: .toWork),
           let schedule = toWorkSchedules[weekday]
        {
            if let scheduleConnectionId = schedule.connectionId, scheduleConnectionId == connection.id {
                return .toWork
            }
            if schedule.departureHour == connHour,
               schedule.departureMinute == connMinute,
               schedule.lineNumber == connection.lineNumber
            {
                return .toWork
            }
        }
        if isDayActive(weekday, direction: .toHome),
           let schedule = toHomeSchedules[weekday]
        {
            if let scheduleConnectionId = schedule.connectionId, scheduleConnectionId == connection.id {
                return .toHome
            }
            if schedule.departureHour == connHour,
               schedule.departureMinute == connMinute,
               schedule.lineNumber == connection.lineNumber
            {
                return .toHome
            }
        }
        return nil
    }

    func hasActiveReminder(for connection: TrainConnection) -> Bool {
        guard let direction = matchesSchedule(connection) else { return false }
        let calendar = Calendar.current
        let connectionDay = calendar.startOfDay(for: connection.departureTime)
        if skippedDates.contains(where: { calendar.isDate($0, inSameDayAs: connectionDay) }) { return false }
        return !isOccurrenceSkipped(on: connectionDay, direction: direction)
    }

    mutating func skipDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if !skippedDates.contains(where: { Calendar.current.isDate($0, inSameDayAs: day) }) { skippedDates.append(day) }
    }

    mutating func skipOccurrence(on date: Date, direction: CommuteDirection) {
        let day = Calendar.current.startOfDay(for: date)
        if !isOccurrenceSkipped(on: day, direction: direction) {
            skippedOccurrences.append(SkippedCommuteOccurrence(date: day, direction: direction))
        }
    }

    func isOccurrenceSkipped(on date: Date, direction: CommuteDirection) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        return skippedOccurrences.contains {
            $0.direction == direction && Calendar.current.isDate($0.date, inSameDayAs: day)
        }
    }

    mutating func pruneOldSkippedDates() {
        let yesterday = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))
        skippedDates.removeAll { $0 < yesterday }
        skippedOccurrences.removeAll { $0.date < yesterday }
    }

    private static func sanitizedActiveDays(_ activeDays: Set<Weekday>, scheduledDays: Dictionary<Weekday, DaySchedule>.Keys)
        -> Set<Weekday>
    {
        let merged = activeDays.union(scheduledDays)
        return merged.isEmpty ? defaultWorkweekDays : merged
    }
}

struct SkippedCommuteOccurrence: Codable, Equatable {
    var date: Date
    var direction: CommuteDirection
}

// MARK: - DaySchedule

struct DaySchedule: Codable, Equatable {
    var lineNumber: String
    var lineColors: TrainLineColors?
    var departureHour: Int
    var departureMinute: Int
    var connectionId: String?
    var isDailyRepeat: Bool
    var transfers: Int

    var departureTimeString: String { String(format: "%02d:%02d", departureHour, departureMinute) }
}

// MARK: - CommuteDirection

enum CommuteDirection: String, Codable, CaseIterable {
    case toWork = "To Work"
    case toHome = "To Home"

    var title: String { self == .toWork ? "Morning" : "Afternoon" }
}

// MARK: - ScheduledReminder

struct ScheduledReminder: Identifiable, Codable, Equatable {
    let id: String
    let transportType: TransportType
    let lineNumber: String
    let destination: String
    let platform: String?
    let departureTime: Date
    let leaveTime: Date
    let delayMinutes: Int
    let fiveMinuteWarning: Bool
    let exactTimeWarning: Bool
    let createdAt: Date
}
