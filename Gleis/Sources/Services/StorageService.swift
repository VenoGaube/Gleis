import Foundation
import os

// MARK: - StorageKey

enum StorageKey: String {
    case appSettings, trainCommuteConfig, cachedStations, oebbAuthSession, scheduledReminders, savedCommuteRoute,
         archivedSchedulesByStationPair, pinnedJourney, deliveredServiceAlerts
}

// MARK: - ArchivedSchedules

/// Archived schedules for a station pair, allowing restoration when switching back
struct ArchivedSchedules: Codable {
    var toWorkSchedules: [Weekday: DaySchedule]
    var toHomeSchedules: [Weekday: DaySchedule]
    var toWorkActiveDays: Set<Weekday>
    var toHomeActiveDays: Set<Weekday>

    private enum CodingKeys: String, CodingKey {
        case toWorkSchedules
        case toHomeSchedules
        case toWorkActiveDays
        case toHomeActiveDays
    }

    init(
        toWorkSchedules: [Weekday: DaySchedule],
        toHomeSchedules: [Weekday: DaySchedule],
        toWorkActiveDays: Set<Weekday>,
        toHomeActiveDays: Set<Weekday>
    ) {
        self.toWorkSchedules = toWorkSchedules
        self.toHomeSchedules = toHomeSchedules
        self.toWorkActiveDays = toWorkActiveDays
        self.toHomeActiveDays = toHomeActiveDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toWorkSchedules = try container.decodeIfPresent([Weekday: DaySchedule].self, forKey: .toWorkSchedules) ?? [:]
        toHomeSchedules = try container.decodeIfPresent([Weekday: DaySchedule].self, forKey: .toHomeSchedules) ?? [:]
        toWorkActiveDays =
            try container.decodeIfPresent(Set<Weekday>.self, forKey: .toWorkActiveDays)
            ?? Set(Weekday.workweek).union(toWorkSchedules.keys)
        toHomeActiveDays =
            try container.decodeIfPresent(Set<Weekday>.self, forKey: .toHomeActiveDays)
            ?? Set(Weekday.workweek).union(toHomeSchedules.keys)
    }
}

// MARK: - LocalStorageService

final class LocalStorageService: StorageServiceProtocol, @unchecked Sendable {
    static let shared = LocalStorageService()
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.veno.gleis", category: "Storage")

    private init() {}

    func save(_ value: some Codable, forKey key: String) throws { try defaults.set(encoder.encode(value), forKey: key) }

    func load<T: Codable>(forKey key: String) throws -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Diagnostic copy only, since the caller's next save overwrites the key; the session token is never copied.
            let backupKey = Self.corruptBackupKey(for: key)
            if key != StorageKey.oebbAuthSession.rawValue, defaults.object(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            logger.error(
                "Failed to decode stored value for key \(key, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    func delete(forKey key: String) throws {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: Self.corruptBackupKey(for: key))
    }

    private static func corruptBackupKey(for key: String) -> String { "\(key).corrupt" }
}

// MARK: - SettingsManager

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var appSettings: AppSettings
    @Published var trainCommuteConfig: RouteConfiguration
    @Published var scheduledReminders: [ScheduledReminder]
    @Published var savedCommuteRoute: SavedCommuteRoute
    @Published var pinnedJourney: PinnedJourney?

    private let storage: StorageServiceProtocol
    private var archivedSchedulesByStationPair: [String: ArchivedSchedules]

    private init(storage: StorageServiceProtocol = LocalStorageService.shared) {
        self.storage = storage
        let loadedAppSettings: AppSettings = (try? storage.load(forKey: StorageKey.appSettings.rawValue)) ?? AppSettings()
        appSettings = loadedAppSettings
        trainCommuteConfig =
            (try? storage.load(forKey: StorageKey.trainCommuteConfig.rawValue))
            ?? RouteConfiguration()
        scheduledReminders = (try? storage.load(forKey: StorageKey.scheduledReminders.rawValue)) ?? []
        savedCommuteRoute =
            (try? storage.load(forKey: StorageKey.savedCommuteRoute.rawValue)) ?? SavedCommuteRoute()
        archivedSchedulesByStationPair =
            (try? storage.load(forKey: StorageKey.archivedSchedulesByStationPair.rawValue)) ?? [:]
        pinnedJourney = (try? storage.load(forKey: StorageKey.pinnedJourney.rawValue))
        if loadedAppSettings.containsLegacyTicketData {
            try? storage.save(loadedAppSettings, forKey: StorageKey.appSettings.rawValue)
        }
    }

    func updateConfig(_ config: RouteConfiguration) {
        trainCommuteConfig = config
        try? storage.save(config, forKey: StorageKey.trainCommuteConfig.rawValue)
    }

    func updateAppSettings(_ settings: AppSettings) {
        appSettings = settings
        try? storage.save(settings, forKey: StorageKey.appSettings.rawValue)
    }

    func isReminderSet(for connectionId: String) -> Bool { scheduledReminders.contains { $0.id == connectionId } }

    func upsertReminder(_ reminder: ScheduledReminder) {
        scheduledReminders.removeAll { $0.id == reminder.id }
        scheduledReminders.insert(reminder, at: 0)
        try? storage.save(scheduledReminders, forKey: StorageKey.scheduledReminders.rawValue)
    }

    func removeReminder(connectionId: String) {
        scheduledReminders.removeAll { $0.id == connectionId }
        try? storage.save(scheduledReminders, forKey: StorageKey.scheduledReminders.rawValue)
    }

    /// Drops reminders whose leave time has passed. Cheap to call often: it only
    /// publishes and touches storage when something was actually removed.
    @discardableResult
    func pruneExpiredReminders(before date: Date = Date()) -> Int {
        let remaining = scheduledReminders.filter { $0.leaveTime >= date }
        let removed = scheduledReminders.count - remaining.count
        guard removed > 0 else { return 0 }
        scheduledReminders = remaining
        try? storage.save(scheduledReminders, forKey: StorageKey.scheduledReminders.rawValue)
        return removed
    }

    // MARK: - Pinned Journey Management

    func pinJourney(_ connection: TrainConnection) {
        let journey = PinnedJourney(from: connection)
        pinnedJourney = journey
        try? storage.save(journey, forKey: StorageKey.pinnedJourney.rawValue)
    }

    func unpinJourney() {
        pinnedJourney = nil
        try? storage.delete(forKey: StorageKey.pinnedJourney.rawValue)
    }

    /// Pure query. Expiry is handled by `checkAndClearExpiredPin()`, which callers
    /// invoke explicitly — this used to unpin as a side effect, which meant writing
    /// `@Published` state from inside a SwiftUI view update.
    func isPinned(_ connectionId: String) -> Bool {
        guard let pinned = pinnedJourney, !pinned.shouldAutoUnpin() else { return false }
        return pinned.connectionId == connectionId
    }

    /// Brings the stored pin back in line with live data for the same journey.
    func syncPinnedJourney(with connections: [TrainConnection]) {
        guard let pinned = pinnedJourney,
              let live = connections.first(where: { $0.id == pinned.connectionId })
        else { return }

        let updated = pinned.refreshed(from: live)
        guard updated != pinned else { return }
        pinnedJourney = updated
        try? storage.save(updated, forKey: StorageKey.pinnedJourney.rawValue)
    }

    func checkAndClearExpiredPin() {
        guard let pinned = pinnedJourney, pinned.shouldAutoUnpin() else { return }
        unpinJourney()
    }

    // MARK: - Station Favorites & Timing

    func toggleFavoriteStation(_ station: Station) {
        var cfg = trainCommuteConfig
        cfg.toggleFavoriteStation(station)
        updateConfig(cfg)
    }

    func saveTravelTime(_ minutes: Int?, for stationId: String) {
        var cfg = trainCommuteConfig
        cfg.setTravelTime(minutes, for: stationId)
        updateConfig(cfg)
    }

    func saveBufferTime(_ minutes: Int?, for stationId: String) {
        var cfg = trainCommuteConfig
        cfg.setBufferTime(minutes, for: stationId)
        updateConfig(cfg)
    }

    func addRecentStation(_ station: Station) {
        var cfg = trainCommuteConfig
        cfg.addRecentStation(station)
        updateConfig(cfg)
    }

    func updateSavedCommuteRoute(_ route: SavedCommuteRoute) {
        savedCommuteRoute = route
        try? storage.save(route, forKey: StorageKey.savedCommuteRoute.rawValue)
    }

    // MARK: - Station Pair Schedule Archiving

    /// Creates a unique key for a station pair
    private func stationPairKey(start: Station?, end: Station?) -> String? {
        guard let startId = start?.id, let endId = end?.id else { return nil }
        return "\(startId)_\(endId)"
    }

    /// Archives current schedules for the given station pair
    func archiveSchedulesForCurrentStations() {
        guard let key = stationPairKey(start: savedCommuteRoute.homeStation, end: savedCommuteRoute.workStation) else {
            return
        }
        // Only archive if there are schedules to save
        guard !savedCommuteRoute.toWorkSchedules.isEmpty || !savedCommuteRoute.toHomeSchedules.isEmpty else { return }

        let archived = ArchivedSchedules(
            toWorkSchedules: savedCommuteRoute.toWorkSchedules,
            toHomeSchedules: savedCommuteRoute.toHomeSchedules,
            toWorkActiveDays: savedCommuteRoute.toWorkActiveDays,
            toHomeActiveDays: savedCommuteRoute.toHomeActiveDays
        )
        archivedSchedulesByStationPair[key] = archived
        try? storage.save(archivedSchedulesByStationPair, forKey: StorageKey.archivedSchedulesByStationPair.rawValue)
    }

    /// Restores archived schedules for a station pair, or clears schedules if none exist
    func restoreSchedulesForStationPair(start: Station?, end: Station?) {
        var route = savedCommuteRoute
        route.homeStation = start
        route.workStation = end

        // If stations are incomplete, just set the stations and clear schedules
        guard let key = stationPairKey(start: start, end: end) else {
            route.toWorkSchedules = [:]
            route.toHomeSchedules = [:]
            route.toWorkActiveDays = Set(Weekday.workweek)
            route.toHomeActiveDays = Set(Weekday.workweek)
            updateSavedCommuteRoute(route)
            return
        }

        if let archived = archivedSchedulesByStationPair[key] {
            // Restore archived schedules
            route.toWorkSchedules = archived.toWorkSchedules
            route.toHomeSchedules = archived.toHomeSchedules
            route.toWorkActiveDays = archived.toWorkActiveDays.union(route.toWorkSchedules.keys)
            route.toHomeActiveDays = archived.toHomeActiveDays.union(route.toHomeSchedules.keys)
        } else {
            // No archived schedules for this pair - clear schedules
            route.toWorkSchedules = [:]
            route.toHomeSchedules = [:]
            route.toWorkActiveDays = Set(Weekday.workweek)
            route.toHomeActiveDays = Set(Weekday.workweek)
        }
        updateSavedCommuteRoute(route)
    }

    /// Handles station change - archives old schedules, restores or clears for new pair
    func handleStationChange(oldStart: Station?, oldEnd: Station?, newStart: Station?, newEnd: Station?) {
        // If nothing actually changed, do nothing
        guard oldStart?.id != newStart?.id || oldEnd?.id != newEnd?.id else { return }

        let oldKey = stationPairKey(start: oldStart, end: oldEnd)
        let newKey = stationPairKey(start: newStart, end: newEnd)

        // Archive current schedules for the old station pair (only if we had a complete pair)
        if oldKey != nil { archiveSchedulesForCurrentStations() }

        // Restore archived schedules only if switching between complete pairs
        // Otherwise just update the stations
        if oldKey != newKey {
            restoreSchedulesForStationPair(start: newStart, end: newEnd)
        } else {
            // Same archive key but station changed - just update stations without restoring
            var route = savedCommuteRoute
            route.homeStation = newStart
            route.workStation = newEnd
            updateSavedCommuteRoute(route)
        }
    }
}
