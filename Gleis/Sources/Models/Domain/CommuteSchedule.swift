import Foundation

// MARK: - SavedCommuteRoute

struct SavedCommuteRoute: Identifiable, Codable, Equatable {
    let id: UUID
    var isEnabled: Bool
    var homeStation: Station?
    var workStation: Station?
    var toWorkSchedules: [Weekday: DaySchedule]
    var toHomeSchedules: [Weekday: DaySchedule]
    var notifyFiveMinBefore: Bool
    var notifyAtLeaveTime: Bool
    var skippedDates: [Date]

    init() {
        self.id = UUID()
        self.isEnabled = false
        self.toWorkSchedules = [:]
        self.toHomeSchedules = [:]
        self.notifyFiveMinBefore = true
        self.notifyAtLeaveTime = true
        self.skippedDates = []
    }

    var isConfigured: Bool { homeStation != nil && workStation != nil }
    var activeDays: Set<Weekday> { Set(toWorkSchedules.keys).union(toHomeSchedules.keys) }

    func schedule(for day: Weekday, direction: CommuteDirection = .toWork) -> DaySchedule? {
        direction == .toWork ? toWorkSchedules[day] : toHomeSchedules[day]
    }

    func fromStation(for direction: CommuteDirection) -> Station? {
        direction == .toWork ? homeStation : workStation
    }

    func toStation(for direction: CommuteDirection) -> Station? {
        direction == .toWork ? workStation : homeStation
    }

    mutating func setSchedule(_ schedule: DaySchedule, for day: Weekday, direction: CommuteDirection) {
        if direction == .toWork { toWorkSchedules[day] = schedule }
        else { toHomeSchedules[day] = schedule }
    }

    mutating func removeSchedule(for day: Weekday, direction: CommuteDirection) {
        if direction == .toWork { toWorkSchedules.removeValue(forKey: day) }
        else { toHomeSchedules.removeValue(forKey: day) }
    }

    func matchesSchedule(_ connection: TrainConnection) -> CommuteDirection? {
        let calendar = Calendar.current
        let connectionDay = calendar.startOfDay(for: connection.departureTime)
        if skippedDates.contains(where: { calendar.isDate($0, inSameDayAs: connectionDay) }) { return nil }
        guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: connection.departureTime)) else { return nil }

        let connHour = calendar.component(.hour, from: connection.departureTime)
        let connMinute = calendar.component(.minute, from: connection.departureTime)

        if let schedule = toWorkSchedules[weekday], schedule.departureHour == connHour,
           schedule.departureMinute == connMinute, schedule.lineNumber == connection.lineNumber { return .toWork }
        if let schedule = toHomeSchedules[weekday], schedule.departureHour == connHour,
           schedule.departureMinute == connMinute, schedule.lineNumber == connection.lineNumber { return .toHome }
        return nil
    }

    mutating func skipDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if !skippedDates.contains(where: { Calendar.current.isDate($0, inSameDayAs: day) }) {
            skippedDates.append(day)
        }
    }

    mutating func pruneOldSkippedDates() {
        let yesterday = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))
        skippedDates.removeAll { $0 < yesterday }
    }
}

// MARK: - DaySchedule

struct DaySchedule: Codable, Equatable {
    var lineNumber: String
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

    var icon: String { self == .toWork ? "building.2.fill" : "house.fill" }
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
