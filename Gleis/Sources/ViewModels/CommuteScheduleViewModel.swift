import Combine
import CoreLocation
import Foundation

@MainActor
final class CommuteScheduleViewModel: ObservableObject {
    // MARK: - Published State

    @Published var route: SavedCommuteRoute = .init()
    @Published var stations: [Station] = []
    @Published var selectedDirection: CommuteDirection = .toWork

    let toastManager = ToastManager()
    let nearbyStationService: NearbyStationService

    // MARK: - Dependencies

    let transportType: TransportType
    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let settingsManager: SettingsManager
    private let locationService: LocationService
    private let searchService: StationSearchService
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var config: RouteConfiguration { settingsManager.config(for: transportType) }
    var currentFromStation: Station? { selectedDirection == .toWork ? route.homeStation : route.workStation }
    var currentToStation: Station? { selectedDirection == .toWork ? route.workStation : route.homeStation }
    var hasSchedules: Bool { !route.toWorkSchedules.isEmpty || !route.toHomeSchedules.isEmpty }
    var recentStations: [Station] { config.recentStations }
    var favoriteStations: [Station] { config.favoriteStations }

    // MARK: - Init

    init(
        transportType: TransportType = .trainCommute,
        transportService: TransportServiceProtocol = TransportService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        settingsManager: SettingsManager? = nil,
        locationService: LocationService = LocationService.shared
    ) {
        self.transportType = transportType
        self.transportService = transportService
        self.notificationService = notificationService
        self.settingsManager = settingsManager ?? SettingsManager.shared
        self.locationService = locationService
        nearbyStationService = NearbyStationService(
            transportService: transportService,
            locationService: locationService
        )
        searchService = StationSearchService(
            transportService: transportService,
            nearbyStationService: nearbyStationService
        )
    }

    // MARK: - Lifecycle

    func onAppear() async {
        route = settingsManager.savedCommuteRoute
        do {
            stations = try await transportService.fetchStations(for: transportType)
        } catch {}
        await nearbyStationService.refreshIfNeeded(transportType: transportType)
        locationService.startUpdatingLocation()
        observeLocationChanges()
    }

    // MARK: - Station Search

    func searchStations(_ query: String) async -> [Station] {
        await searchService.searchStations(query, transportType: transportType)
    }

    // MARK: - Favorites

    func toggleFavorite(_ station: Station) {
        settingsManager.toggleFavoriteStation(station, for: transportType)
    }

    // MARK: - Timing

    func saveTravelTime(_ minutes: Int?, for station: Station) {
        settingsManager.saveTravelTime(minutes, for: station.id, transportType: transportType)
    }

    func saveBufferTime(_ minutes: Int?, for station: Station) {
        settingsManager.saveBufferTime(minutes, for: station.id, transportType: transportType)
    }

    // MARK: - Station Changes

    func handleStationAChange(_ newStation: Station?) {
        let old = (route.homeStation, route.workStation)
        settingsManager.handleStationChange(
            oldStart: old.0, oldEnd: old.1, newStart: newStation, newEnd: old.1
        )
        route = settingsManager.savedCommuteRoute
        rescheduleAllNotifications()
    }

    func handleStationBChange(_ newStation: Station?) {
        let old = (route.homeStation, route.workStation)
        settingsManager.handleStationChange(
            oldStart: old.0, oldEnd: old.1, newStart: old.0, newEnd: newStation
        )
        route = settingsManager.savedCommuteRoute
        rescheduleAllNotifications()
    }

    // MARK: - Schedule Management

    func save() {
        settingsManager.updateSavedCommuteRoute(route)
    }

    func clearSchedule(day: Weekday, direction: CommuteDirection) {
        notificationService.cancelCommuteNotification(day: day, direction: direction)
        route.removeSchedule(for: day, direction: direction)
        save()
        toastManager.show("Cleared \(day.fullName) schedule", type: .info)
    }

    func resetToDefaults() {
        Haptics.notification(.warning)
        route = SavedCommuteRoute()
        save()
    }

    func clearAllSchedules() {
        route.toWorkSchedules = [:]
        route.toHomeSchedules = [:]
        notificationService.cancelAllCommuteNotifications()
        save()
    }

    // MARK: - Notifications

    func rescheduleAllNotifications() {
        Task {
            notificationService.cancelAllCommuteNotifications()
            let cfg = config
            for (day, schedule) in route.toWorkSchedules {
                try? await notificationService.scheduleCommuteNotification(
                    route: route, day: day, schedule: schedule, direction: .toWork, config: cfg
                )
            }
            for (day, schedule) in route.toHomeSchedules {
                try? await notificationService.scheduleCommuteNotification(
                    route: route, day: day, schedule: schedule, direction: .toHome, config: cfg
                )
            }
        }
    }

    func cancelNotificationsForSchedule(day: Weekday, direction: CommuteDirection) {
        notificationService.cancelCommuteNotification(day: day, direction: direction)
    }

    // MARK: - Private

    private func observeLocationChanges() {
        locationService.$currentLocation
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.nearbyStationService.refreshIfNeeded(transportType: self.transportType) }
            }
            .store(in: &cancellables)
    }
}
