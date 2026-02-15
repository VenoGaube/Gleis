import CoreLocation
import Foundation

// MARK: - StorageKey

enum StorageKey: String {
    case appSettings, trainCommuteConfig, cachedStations, oebbAuthSession, scheduledReminders, savedCommuteRoute,
         archivedSchedulesByStationPair, pinnedJourney
}

// MARK: - ArchivedSchedules

/// Archived schedules for a station pair, allowing restoration when switching back
struct ArchivedSchedules: Codable {
    var toWorkSchedules: [Weekday: DaySchedule]
    var toHomeSchedules: [Weekday: DaySchedule]
}

// MARK: - LocalStorageService

final class LocalStorageService: StorageServiceProtocol {
    static let shared = LocalStorageService()
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func save(_ value: some Codable, forKey key: String) throws { try defaults.set(encoder.encode(value), forKey: key) }

    func load<T: Codable>(forKey key: String) throws -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try decoder.decode(T.self, from: data)
    }

    func delete(forKey key: String) throws { defaults.removeObject(forKey: key) }
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
        appSettings = (try? storage.load(forKey: StorageKey.appSettings.rawValue)) ?? AppSettings()
        trainCommuteConfig =
            (try? storage.load(forKey: StorageKey.trainCommuteConfig.rawValue))
            ?? RouteConfiguration(transportType: .trainCommute)
        scheduledReminders = (try? storage.load(forKey: StorageKey.scheduledReminders.rawValue)) ?? []
        savedCommuteRoute =
            (try? storage.load(forKey: StorageKey.savedCommuteRoute.rawValue)) ?? SavedCommuteRoute()
        archivedSchedulesByStationPair =
            (try? storage.load(forKey: StorageKey.archivedSchedulesByStationPair.rawValue)) ?? [:]
        pinnedJourney = (try? storage.load(forKey: StorageKey.pinnedJourney.rawValue))
    }

    func config(for _: TransportType) -> RouteConfiguration { trainCommuteConfig }

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

    func pruneExpiredReminders(before date: Date = Date()) {
        scheduledReminders.removeAll { $0.leaveTime < date }
        try? storage.save(scheduledReminders, forKey: StorageKey.scheduledReminders.rawValue)
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

    func isPinned(_ connectionId: String) -> Bool {
        guard let pinned = pinnedJourney else { return false }
        // Auto-unpin if arrival time passed
        if pinned.shouldAutoUnpin() {
            unpinJourney()
            return false
        }
        return pinned.connectionId == connectionId
    }

    func checkAndClearExpiredPin() {
        guard let pinned = pinnedJourney, pinned.shouldAutoUnpin() else { return }
        unpinJourney()
    }

    // MARK: - Station Favorites & Timing

    func toggleFavoriteStation(_ station: Station, for transportType: TransportType = .trainCommute) {
        var cfg = config(for: transportType)
        cfg.toggleFavoriteStation(station)
        updateConfig(cfg)
    }

    func saveTravelTime(_ minutes: Int?, for stationId: String, transportType: TransportType = .trainCommute) {
        var cfg = config(for: transportType)
        cfg.setTravelTime(minutes, for: stationId)
        updateConfig(cfg)
    }

    func saveBufferTime(_ minutes: Int?, for stationId: String, transportType: TransportType = .trainCommute) {
        var cfg = config(for: transportType)
        cfg.setBufferTime(minutes, for: stationId)
        updateConfig(cfg)
    }

    func addRecentStation(_ station: Station, for transportType: TransportType = .trainCommute) {
        var cfg = config(for: transportType)
        cfg.addRecentStation(station)
        updateConfig(cfg)
    }

    func setPreferredAutoSelectionStation(_ station: Station, at location: CLLocation) {
        var settings = appSettings
        settings.setPreferredAutoStation(stationId: station.id, stationName: station.name, location: location)
        settings.setAutoSelectionExcluded(station.id, excluded: false)
        updateAppSettings(settings)
    }

    @discardableResult
    func toggleAutoSelectionExclusion(for station: Station) -> Bool {
        let wasExcluded = appSettings.autoSelectionPreferences.excludedStationIds.contains(station.id)
        var settings = appSettings
        settings.setAutoSelectionExcluded(station.id, excluded: !wasExcluded)
        updateAppSettings(settings)
        return !wasExcluded
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
            toHomeSchedules: savedCommuteRoute.toHomeSchedules
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
            updateSavedCommuteRoute(route)
            return
        }

        if let archived = archivedSchedulesByStationPair[key] {
            // Restore archived schedules
            route.toWorkSchedules = archived.toWorkSchedules
            route.toHomeSchedules = archived.toHomeSchedules
        } else {
            // No archived schedules for this pair - clear schedules
            route.toWorkSchedules = [:]
            route.toHomeSchedules = [:]
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
