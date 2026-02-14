import Combine
import CoreLocation
import Foundation
import WidgetKit

@MainActor
final class TransportViewModel: ObservableObject {
    @Published var connections: LoadingState<[TrainConnection]> = .idle
    @Published var displayConnections: [DisplayConnection] = []
    @Published var stations: [Station] = []
    @Published var selectedConnection: TrainConnection?
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var isShowingCachedData = false
    @Published var lastUpdated: Date?
    @Published var isLoadingMore = false
    @Published var availableTrainTypes: [TrainType] = []

    let transportType: TransportType
    let toastManager = ToastManager()
    let nearbyStationService: NearbyStationService

    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let settingsManager: SettingsManager
    private let locationService: LocationService
    private let searchService: StationSearchService
    private let connectionCache = ConnectionCache.shared
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var currentFetchTask: Task<Void, Never>?
    private var lastFetchedRouteKey: String?
    private var isFetching = false
    private var isLoadingStations = false
    private var lastWidgetUpdate: Date?

    var config: RouteConfiguration { settingsManager.config(for: transportType) }

    init(
        transportType: TransportType, transportService: TransportServiceProtocol = TransportService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        settingsManager: SettingsManager? = nil, locationService: LocationService = LocationService.shared
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

        Task {
            await loadStations()
            await nearbyStationService.refreshIfNeeded(transportType: transportType)
        }
        observeConfigChanges()
        observeLocationChanges()
    }

    private func observeConfigChanges() {
        // Watch for route changes (start/end station) - triggers full refresh
        settingsManager.$trainCommuteConfig.dropFirst().removeDuplicates {
            $0.startStation?.id == $1.startStation?.id && $0.endStation?.id == $1.endStation?.id
        }.debounce(for: .milliseconds(300), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            lastFetchedRouteKey = nil
            currentFetchTask?.cancel()
            currentFetchTask = Task { await self.refreshConnections(isUserInitiated: true) }
        }.store(in: &cancellables)

        // Watch for travel time/buffer time/filter changes - only updates display (no re-fetch needed)
        settingsManager.$trainCommuteConfig.dropFirst().removeDuplicates { old, new in
            old.stationTravelTimes == new.stationTravelTimes && old.stationBufferTimes == new.stationBufferTimes
                && old.excludedTrainTypes == new.excludedTrainTypes
        }.debounce(for: .milliseconds(100), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            rebuildDisplayConnections()
            if let loadedConnections = connections.value { updateWidgetIfNeeded(with: loadedConnections) }
        }.store(in: &cancellables)
    }

    private func observeLocationChanges() {
        locationService.$currentLocation.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main).sink {
            [weak self] _ in
            guard let self else { return }
            Task { await self.nearbyStationService.refreshIfNeeded(transportType: self.transportType) }
        }.store(in: &cancellables)
    }

    func loadStations() async {
        guard !isLoadingStations else { return }
        isLoadingStations = true
        defer { isLoadingStations = false }
        do { stations = try await transportService.fetchStations(for: transportType) } catch {
            if !(error is CancellationError) { handleError(error) }
        }
    }

    func searchStations(_ query: String) async -> [Station] {
        await searchService.searchStations(query, transportType: transportType)
    }

    func refreshConnections(showFeedback: Bool = false, isUserInitiated: Bool = false) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let currentConfig = config
        guard let start = currentConfig.startStation, let end = currentConfig.endStation, start.id != end.id else {
            connections = .idle
            isShowingCachedData = false
            updateWidget(with: [])
            return
        }

        let routeKey = "\(start.id)-\(end.id)"
        let existingConnections: [TrainConnection]? = connections.value
        let isRouteChange = routeKey != lastFetchedRouteKey

        // Skip fetch if route unchanged, already loaded, and not user-initiated
        // But still filter out past connections from existing state
        if !isUserInitiated && !isRouteChange && connections.isLoaded {
            if let existing = connections.value {
                let now = Date()
                let pinnedId = settingsManager.pinnedJourney?.connectionId
                let stillFuture = existing.filter { $0.departureTime > now || $0.id == pinnedId }
                if stillFuture.count != existing.count {
                    setConnections(stillFuture)
                    updateWidgetIfNeeded(with: stillFuture)
                }
            }
            return
        }

        // Offline: use cached data
        if !NetworkMonitor.shared.isConnected,
           let cached = await connectionCache.load(for: transportType, from: start, to: end)
        {
            let futureConnections = cached.connections.filter { $0.departureTime > Date() }
            guard !futureConnections.isEmpty else {
                connections = .error(.noConnectionsAvailable)
                return
            }
            lastFetchedRouteKey = routeKey
            setConnections(futureConnections)
            isShowingCachedData = true
            lastUpdated = await connectionCache.lastUpdateTime(for: transportType)
            updateWidgetIfNeeded(with: futureConnections)
            return
        }

        // Only show loading skeleton if we have no existing data or route changed
        if existingConnections == nil || isRouteChange {
            connections = .loading
            isShowingCachedData = false
        }

        do {
            let fetchCount = 5
            let result = try await fetchConnectionsWithTimeout(from: start, to: end, count: fetchCount)
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            await connectionCache.save(result, for: transportType, from: start, to: end)

            let now = Date()
            let futureResult = result.filter { $0.departureTime > now }

            let merged: [TrainConnection]
            if let existing = existingConnections, !isRouteChange, !isUserInitiated {
                let stillValid = existing.filter { $0.departureTime > now }
                let newIds = Set(futureResult.map(\.id))
                let kept = stillValid.filter { !newIds.contains($0.id) }
                merged = (futureResult + kept).sorted { $0.departureTime < $1.departureTime }
            } else {
                merged = futureResult
            }

            lastFetchedRouteKey = routeKey
            setConnections(merged)
            lastUpdated = Date()
            isShowingCachedData = false
            if showFeedback { toastManager.show("Updated", type: .success) }
            updateWidgetIfNeeded(with: merged)
        } catch {
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            if let existing = existingConnections, !existing.isEmpty {
                if !(error is CancellationError) {
                    toastManager.show("Update failed, showing previous data", type: .info)
                }
                return
            }
            if let cached = await connectionCache.load(for: transportType, from: start, to: end) {
                let futureConnections = cached.connections.filter { $0.departureTime > Date() }
                guard !futureConnections.isEmpty else {
                    connections = .error(.noConnectionsAvailable)
                    handleError(error)
                    return
                }
                lastFetchedRouteKey = routeKey
                setConnections(futureConnections)
                isShowingCachedData = true
                lastUpdated = await connectionCache.lastUpdateTime(for: transportType)
                toastManager.show("Showing cached data", type: .info)
                updateWidgetIfNeeded(with: futureConnections)
            } else {
                connections = .error((error as? GleisError) ?? .unknown(error.localizedDescription))
                handleError(error)
            }
        }
    }

    func scheduleNotification(for connection: TrainConnection) async {
        do {
            let fromStationId = config.startStation?.id
            try await notificationService.scheduleNotification(
                for: connection, config: config, type: .fiveMinuteWarning, fromStationId: fromStationId
            )
            try await notificationService.scheduleNotification(
                for: connection, config: config, type: .exactTime, fromStationId: fromStationId
            )
            toastManager.show("Reminder set for \(connection.lineNumber.uppercased())", type: .success)
            selectedConnection = connection

            let reminder = ScheduledReminder(
                id: connection.id, transportType: transportType, lineNumber: connection.lineNumber,
                destination: connection.arrivalStation.name, platform: connection.platform,
                departureTime: config.effectiveDepartureTime(for: connection),
                leaveTime: calculateLeaveTime(for: connection), delayMinutes: connection.delay, fiveMinuteWarning: true,
                exactTimeWarning: true, createdAt: Date()
            )
            settingsManager.upsertReminder(reminder)
            rebuildDisplayConnections()
            if case let .loaded(conns) = connections { updateWidgetIfNeeded(with: conns) }
        } catch {
            if let gleisError = error as? GleisError, case .notificationPermissionDenied = gleisError {
                do {
                    let granted = try await notificationService.requestAuthorization()
                    if granted {
                        await scheduleNotification(for: connection)
                    } else {
                        toastManager.show("Notifications permission required", type: .error)
                        errorMessage = "Enable notifications in Settings to receive reminders"
                        showError = true
                    }
                } catch { handleError(error) }
            } else {
                handleError(error)
            }
        }
    }

    func cancelNotification(for connection: TrainConnection) {
        notificationService.cancelNotification(id: "\(connection.id)_fiveMinuteWarning")
        notificationService.cancelNotification(id: "\(connection.id)_exactTime")
        if selectedConnection?.id == connection.id { selectedConnection = nil }

        if settingsManager.savedCommuteRoute.matchesSchedule(connection) != nil {
            var route = settingsManager.savedCommuteRoute
            route.skipDate(connection.departureTime)
            route.pruneOldSkippedDates()
            settingsManager.updateSavedCommuteRoute(route)
            toastManager.show("Skipped for today", type: .info)
        } else {
            settingsManager.removeReminder(connectionId: connection.id)
            toastManager.show("Reminder cancelled", type: .info)
        }
    }

    func calculateLeaveTime(for connection: TrainConnection) -> Date {
        config.leaveTime(for: connection, fromStationId: config.startStation?.id)
    }

    func pinJourney(for connection: TrainConnection) {
        settingsManager.pinJourney(connection)
        toastManager.show("Pinned as My Journey", type: .success)
        rebuildDisplayConnections()
        if case let .loaded(conns) = connections { updateWidgetIfNeeded(with: conns) }
    }

    func unpinJourney(for _: TrainConnection) {
        settingsManager.unpinJourney()
        toastManager.show("Unpinned journey", type: .info)
        rebuildDisplayConnections()
        if case let .loaded(conns) = connections { updateWidgetIfNeeded(with: conns) }
    }

    func isPinned(_ connectionId: String) -> Bool { settingsManager.isPinned(connectionId) }

    func addRecentStation(_ station: Station) {
        settingsManager.addRecentStation(station, for: transportType)
    }

    func loadMoreConnections() async {
        guard case let .loaded(current) = connections, let last = current.last else { return }
        guard !isLoadingMore, !isFetching else { return }
        guard let start = config.startStation, let end = config.endStation else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let pageSize = config.displayMaxConnections

        do {
            let more = try await transportService.fetchConnections(
                from: start, to: end, transportType: transportType,
                departureTime: last.departureTime.addingTimeInterval(60), count: pageSize
            )
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            let now = Date()
            let newConns = more.filter { new in new.departureTime > now && !current.contains { $0.id == new.id } }
            guard !newConns.isEmpty else { return }
            setConnections(current + newConns)
        } catch { if !(error is CancellationError) { toastManager.show("Failed to load more", type: .error) } }
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingsManager.checkAndClearExpiredPin()
                self?.currentFetchTask?.cancel()
                self?.currentFetchTask = Task { await self?.refreshConnections() }
            }
        }
        startDisplayTimer()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopDisplayTimer()
    }

    func cancelCurrentFetch() {
        currentFetchTask?.cancel()
        currentFetchTask = nil
        isFetching = false
    }

    deinit {
        refreshTimer?.invalidate()
        displayTimer?.invalidate()
        currentFetchTask?.cancel()
    }

    // MARK: - Display Connection Management

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDisplayConnectionTimes() }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateDisplayConnectionTimes() {
        let currentTime = Date()
        for i in 0 ..< displayConnections.count {
            displayConnections[i].updateTime(currentTime: currentTime)
        }
    }

    private func rebuildDisplayConnections() {
        guard let connections = connections.value else {
            displayConnections = []
            availableTrainTypes = []
            return
        }

        // Update available train types from all connections (before filtering)
        let types = Set(connections.map(\.trainType))
        availableTrainTypes = types.sorted()

        let excluded = config.excludedTrainTypes
        let filtered = excluded.isEmpty ? connections : connections.filter { !excluded.contains($0.trainType) }

        let currentTime = Date()
        displayConnections = filtered.compactMap { connection in
            let leaveTime = calculateLeaveTime(for: connection)
            let isSelected =
                settingsManager.isReminderSet(for: connection.id)
                || settingsManager.savedCommuteRoute.matchesSchedule(connection) != nil
            let isPinned = settingsManager.isPinned(connection.id)

            return DisplayConnection(
                connection: connection, leaveTime: leaveTime, isSelected: isSelected, isPinned: isPinned,
                currentTime: currentTime
            )
        }
    }

    private func setConnections(_ newConnections: [TrainConnection]) {
        connections = .loaded(newConnections)
        rebuildDisplayConnections()
    }

    // MARK: - Widget

    private func updateWidgetIfNeeded(with connections: [TrainConnection]) {
        let now = Date()
        if let lastUpdate = lastWidgetUpdate, now.timeIntervalSince(lastUpdate) < 5 { return }
        lastWidgetUpdate = now
        updateWidget(with: connections)
    }

    private func updateWidget(with connections: [TrainConnection]) {
        let now = Date()
        let futureConnections = connections.filter { $0.departureTime > now }

        let widgetConnections = futureConnections.prefix(3).map { conn -> WidgetConnection in
            let stopCount = conn.legs.first { !$0.isWalking }?.stopCount
            let hasReminder =
                settingsManager.isReminderSet(for: conn.id)
                || settingsManager.savedCommuteRoute.matchesSchedule(conn) != nil
            let isPinned = settingsManager.isPinned(conn.id)
            return WidgetConnection(
                id: conn.id, lineNumber: conn.lineNumber, departureTime: conn.departureTime,
                arrivalTime: conn.arrivalTime, destination: conn.arrivalStation.name, platform: conn.platform,
                transfers: conn.transfers, delay: conn.delay, stopCount: stopCount, hasReminder: hasReminder,
                isPinned: isPinned
            )
        }

        let sorted = widgetConnections.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.departureTime < rhs.departureTime
        }

        let sortedConnections = sorted.compactMap { widgetConn in futureConnections.first { $0.id == widgetConn.id } }
        let leaveTimes = sortedConnections.map { calculateLeaveTime(for: $0) }

        let widgetData = WidgetData(
            transportType: transportType, connections: Array(sorted), leaveTimes: leaveTimes, updatedAt: Date()
        )
        AppGroupStorage.saveWidgetData(for: transportType, data: widgetData)
        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
    }

    // MARK: - Error Handling

    private func handleError(_ error: Error) {
        errorMessage = (error as? GleisError)?.errorDescription ?? error.localizedDescription
        showError = true
        toastManager.show("Error occurred", type: .error)
    }

    private func fetchConnectionsWithTimeout(
        from start: Station, to end: Station, count: Int = 5
    ) async throws -> [TrainConnection] {
        let service = transportService
        let type = transportType

        return try await withThrowingTaskGroup(of: [TrainConnection].self) { group in
            group.addTask {
                try await service.fetchConnections(
                    from: start, to: end, transportType: type, departureTime: Date(), count: count
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw GleisError.networkError("Request timed out")
            }

            guard let result = try await group.next() else {
                throw GleisError.networkError("Request failed")
            }
            group.cancelAll()
            return result
        }
    }
}
