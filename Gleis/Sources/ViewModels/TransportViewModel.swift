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
    @Published var toast: (message: String, type: ToastView.ToastType)?
    @Published var isShowingCachedData = false
    @Published var lastUpdated: Date?
    @Published var isLoadingMore = false
    @Published private(set) var nearbyStations: [Station] = []
    @Published private(set) var stationDistances: [String: Double] = [:]

    let transportType: TransportType
    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let settingsManager: SettingsManager
    private let locationService: LocationService
    private let connectionCache = ConnectionCache.shared
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var currentFetchTask: Task<Void, Never>?
    private var lastFetchedRouteKey: String?
    private var isFetching = false
    private var isLoadingStations = false
    private var lastWidgetUpdate: Date?
    private var lastLocationUpdate: Date?
    private var lastLocation: CLLocation?

    var config: RouteConfiguration { settingsManager.config(for: transportType) }

    init(
        transportType: TransportType,
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

        Task {
            await loadStations()
            // Pre-compute nearby stations after loading stations
            await updateNearbyStations()
        }
        observeConfigChanges()
        observeLocationChanges()
    }

    private func observeConfigChanges() {
        // Watch for route changes (start/end station) - triggers full refresh
        settingsManager.$trainCommuteConfig
            .dropFirst()
            .removeDuplicates { $0.startStation?.id == $1.startStation?.id && $0.endStation?.id == $1.endStation?.id }
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                lastFetchedRouteKey = nil
                currentFetchTask?.cancel()
                currentFetchTask = Task { await self.refreshConnections(isUserInitiated: true) }
            }
            .store(in: &cancellables)

        // Watch for travel time/buffer time changes - only updates widget (no re-fetch needed)
        settingsManager.$trainCommuteConfig
            .dropFirst()
            .removeDuplicates { old, new in
                old.stationTravelTimes == new.stationTravelTimes && old.stationBufferTimes == new.stationBufferTimes
            }
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Rebuild display connections with new travel/buffer times
                rebuildDisplayConnections()
                // Only update widget if we have loaded connections
                if let loadedConnections = connections.value {
                    updateWidgetIfNeeded(with: loadedConnections)
                }
            }
            .store(in: &cancellables)
    }

    private func observeLocationChanges() {
        locationService.$currentLocation
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.updateNearbyStations() }
            }
            .store(in: &cancellables)
    }

    func loadStations() async {
        guard !isLoadingStations else { return }
        isLoadingStations = true
        defer { isLoadingStations = false }
        do { stations = try await transportService.fetchStations(for: transportType) }
        catch { if !(error is CancellationError) { handleError(error) } }
    }

    func searchStations(_ query: String) async -> [Station] {
        do {
            let results = try await transportService.searchStations(matching: query, transportType: transportType)
            let lowercased = query.lowercased()
            return results.filter { $0.name.lowercased().hasPrefix(lowercased) || $0.name.lowercased() == lowercased }
        } catch { if !(error is CancellationError) { showToast("Station search failed", type: .error) }; return [] }
    }

    func updateNearbyStations() async {
        guard let location = locationService.currentLocation else {
            await MainActor.run {
                nearbyStations = []
                stationDistances = [:]
            }
            return
        }

        // Only update if location changed significantly (>100m) or enough time passed (>30s)
        let shouldUpdate: Bool
        if let lastLoc = lastLocation, let lastUpdate = lastLocationUpdate {
            let distanceChange = location.distance(from: lastLoc)
            let timeElapsed = Date().timeIntervalSince(lastUpdate)
            shouldUpdate = distanceChange > 100 || timeElapsed > 30
        } else {
            shouldUpdate = true
        }

        guard shouldUpdate else { return }

        // Calculate distances in a single pass (async, off main thread initially)
        let calculated = await calculateStationDistances(for: stations, from: location)

        await MainActor.run {
            // Update nearby stations (top 6 closest)
            self.nearbyStations = Array(calculated.prefix(6).map(\.station))
            // Update distances dictionary (all stations)
            self.stationDistances = Dictionary(uniqueKeysWithValues: calculated.map { ($0.station.id, $0.distance) })
            self.lastLocation = location
            self.lastLocationUpdate = Date()
        }
    }

    private func calculateStationDistances(for stations: [Station], from location: CLLocation) async -> [(
        station: Station,
        distance: Double
    )] {
        stations.compactMap { station -> (station: Station, distance: Double)? in
            guard let coordinate = station.coordinate else { return nil }
            let stationLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = location.distance(from: stationLocation)
            return (station: station, distance: distance)
        }
        .sorted { $0.distance < $1.distance }
    }

    func refreshConnections(showFeedback: Bool = false, isUserInitiated: Bool = false) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let currentConfig = config
        guard let start = currentConfig.startStation, let end = currentConfig.endStation, start.id != end.id else {
            connections = .idle; isShowingCachedData = false; updateWidget(with: []); return
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
        if !NetworkMonitor.shared.isConnected, let cached = await connectionCache.load(
            for: transportType,
            from: start,
            to: end
        ) {
            let futureConnections = cached.connections.filter { $0.departureTime > Date() }
            guard !futureConnections.isEmpty else { connections = .error(.noConnectionsAvailable); return }
            lastFetchedRouteKey = routeKey
            setConnections(futureConnections)
            isShowingCachedData = true
            lastUpdated = await connectionCache.lastUpdateTime(for: transportType)
            updateWidgetIfNeeded(with: futureConnections)
            return
        }

        // Only show loading skeleton if we have no existing data or route changed
        if existingConnections == nil || isRouteChange {
            connections = .loading; isShowingCachedData = false
        }

        do {
            // Always fetch 5 connections on refresh (user can scroll to load more)
            let fetchCount = 5
            let result = try await fetchConnectionsWithTimeout(from: start, to: end, count: fetchCount)
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            await connectionCache.save(result, for: transportType, from: start, to: end)

            // Filter out past connections from the fetched results
            let now = Date()
            let futureResult = result.filter { $0.departureTime > now }

            // Merge: keep existing connections only for auto-refresh, reset on user-initiated refresh
            let merged: [TrainConnection]
            if let existing = existingConnections, !isRouteChange, !isUserInitiated {
                // Auto-refresh: Filter expired connections from existing, then merge with new
                let stillValid = existing.filter { $0.departureTime > now }
                let newIds = Set(futureResult.map(\.id))
                let kept = stillValid.filter { !newIds.contains($0.id) }
                merged = (futureResult + kept).sorted { $0.departureTime < $1.departureTime }
            } else {
                // User-initiated refresh or route change: show only new results
                merged = futureResult
            }

            lastFetchedRouteKey = routeKey
            setConnections(merged)
            lastUpdated = Date()
            isShowingCachedData = false
            if showFeedback { showToast("Updated", type: .success) }
            updateWidgetIfNeeded(with: merged)
        } catch {
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            // On error, keep existing data if available
            if let existing = existingConnections, !existing.isEmpty {
                // Just keep showing existing data, maybe show a toast
                if !(error is CancellationError) {
                    showToast("Update failed, showing previous data", type: .info)
                }
                return
            }
            // No existing data: try cache
            if let cached = await connectionCache.load(for: transportType, from: start, to: end) {
                let futureConnections = cached.connections.filter { $0.departureTime > Date() }
                guard !futureConnections.isEmpty else { connections = .error(.noConnectionsAvailable); handleError(error); return }
                lastFetchedRouteKey = routeKey
                setConnections(futureConnections)
                isShowingCachedData = true
                lastUpdated = await connectionCache.lastUpdateTime(for: transportType)
                showToast("Showing cached data", type: .info)
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
            // Always schedule both notification types when notifications are enabled
            try await notificationService.scheduleNotification(
                for: connection,
                config: config,
                type: .fiveMinuteWarning,
                fromStationId: fromStationId
            )
            try await notificationService.scheduleNotification(
                for: connection,
                config: config,
                type: .exactTime,
                fromStationId: fromStationId
            )
            showToast("Reminder set for \(connection.lineNumber.uppercased())", type: .success)
            selectedConnection = connection

            let reminder = ScheduledReminder(
                id: connection.id,
                transportType: transportType,
                lineNumber: connection.lineNumber,
                destination: connection.arrivalStation.name,
                platform: connection.platform,
                departureTime: config.effectiveDepartureTime(for: connection),
                leaveTime: calculateLeaveTime(for: connection),
                delayMinutes: connection.delay,
                fiveMinuteWarning: true,
                exactTimeWarning: true,
                createdAt: Date()
            )
            settingsManager.upsertReminder(reminder)
            rebuildDisplayConnections()
            if case let .loaded(conns) = connections { updateWidgetIfNeeded(with: conns) }
        } catch {
            // If permission denied, request authorization and retry
            if let gleisError = error as? GleisError, case .notificationPermissionDenied = gleisError {
                do {
                    let granted = try await notificationService.requestAuthorization()
                    if granted {
                        // Retry scheduling after permission granted
                        await scheduleNotification(for: connection)
                    } else {
                        showToast("Notifications permission required", type: .error)
                        errorMessage = "Enable notifications in Settings to receive reminders"
                        showError = true
                    }
                } catch {
                    handleError(error)
                }
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
            route.skipDate(connection.departureTime); route.pruneOldSkippedDates()
            settingsManager.updateSavedCommuteRoute(route)
            showToast("Skipped for today", type: .info)
        } else {
            settingsManager.removeReminder(connectionId: connection.id)
            showToast("Reminder cancelled", type: .info)
        }
    }

    func calculateLeaveTime(for connection: TrainConnection) -> Date { config.leaveTime(
        for: connection,
        fromStationId: config.startStation?.id
    ) }

    func pinJourney(for connection: TrainConnection) {
        settingsManager.pinJourney(connection)
        showToast("Pinned as My Journey", type: .success)
        rebuildDisplayConnections()
        if case let .loaded(conns) = connections {
            updateWidgetIfNeeded(with: conns)
        }
    }

    func unpinJourney(for _: TrainConnection) {
        settingsManager.unpinJourney()
        showToast("Unpinned journey", type: .info)
        rebuildDisplayConnections()
        if case let .loaded(conns) = connections {
            updateWidgetIfNeeded(with: conns)
        }
    }

    func isPinned(_ connectionId: String) -> Bool {
        settingsManager.isPinned(connectionId)
    }

    func addRecentStation(_ station: Station) {
        var config = config
        config.addRecentStation(station)
        settingsManager.updateConfig(config)
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
                from: start,
                to: end,
                transportType: transportType,
                departureTime: last.departureTime.addingTimeInterval(60),
                count: pageSize
            )
            // Verify route hasn't changed during fetch
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            // Filter out past connections and duplicates
            let now = Date()
            let newConns = more.filter { new in
                new.departureTime > now && !current.contains { $0.id == new.id }
            }
            guard !newConns.isEmpty else { return }
            setConnections(current + newConns)
        } catch {
            if !(error is CancellationError) {
                showToast("Failed to load more", type: .error)
            }
        }
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Check for expired pin before refresh
                self?.settingsManager.checkAndClearExpiredPin()

                self?.currentFetchTask?.cancel()
                // Auto-refresh: not user-initiated, preserves existing connections
                self?.currentFetchTask = Task { await self?.refreshConnections() }
            }
        }

        // Start display timer for live countdown updates
        startDisplayTimer()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopDisplayTimer()
    }

    func cancelCurrentFetch() { currentFetchTask?.cancel(); currentFetchTask = nil; isFetching = false }

    deinit {
        refreshTimer?.invalidate()
        displayTimer?.invalidate()
        currentFetchTask?.cancel()
    }

    // MARK: - Display Connection Management

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDisplayConnectionTimes()
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateDisplayConnectionTimes() {
        let currentTime = Date()
        for i in 0..<displayConnections.count {
            displayConnections[i].updateTime(currentTime: currentTime)
        }
    }

    private func rebuildDisplayConnections() {
        guard let connections = connections.value else {
            displayConnections = []
            return
        }

        let currentTime = Date()
        displayConnections = connections.compactMap { connection in
            let leaveTime = calculateLeaveTime(for: connection)
            let isSelected = settingsManager.isReminderSet(for: connection.id) ||
                settingsManager.savedCommuteRoute.matchesSchedule(connection) != nil
            let isPinned = settingsManager.isPinned(connection.id)

            return DisplayConnection(
                connection: connection,
                leaveTime: leaveTime,
                isSelected: isSelected,
                isPinned: isPinned,
                currentTime: currentTime
            )
        }
    }

    private func setConnections(_ newConnections: [TrainConnection]) {
        connections = .loaded(newConnections)
        rebuildDisplayConnections()
    }

    // MARK: - Private

    /// Debounced widget update - only updates if at least 5 seconds have passed since last update
    private func updateWidgetIfNeeded(with connections: [TrainConnection]) {
        let now = Date()
        if let lastUpdate = lastWidgetUpdate, now.timeIntervalSince(lastUpdate) < 5 {
            return // Skip update if called within 5 seconds
        }
        lastWidgetUpdate = now
        updateWidget(with: connections)
    }

    private func updateWidget(with connections: [TrainConnection]) {
        // Filter out past connections before saving to widget
        let now = Date()
        let futureConnections = connections.filter { $0.departureTime > now }

        let widgetConnections = futureConnections.prefix(3).map { conn -> WidgetConnection in
            let stopCount = conn.legs.first { !$0.isWalking }?.stopCount
            let hasReminder = settingsManager.isReminderSet(for: conn.id) || settingsManager.savedCommuteRoute
                .matchesSchedule(conn) != nil
            let isPinned = settingsManager.isPinned(conn.id)
            return WidgetConnection(
                id: conn.id,
                lineNumber: conn.lineNumber,
                departureTime: conn.departureTime,
                arrivalTime: conn.arrivalTime,
                destination: conn.arrivalStation.name,
                platform: conn.platform,
                transfers: conn.transfers,
                delay: conn.delay,
                stopCount: stopCount,
                hasReminder: hasReminder,
                isPinned: isPinned
            )
        }

        // Sort: pinned first, then by departure time
        let sorted = widgetConnections.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            return lhs.departureTime < rhs.departureTime
        }

        // Recalculate leave times after sorting
        let sortedConnections = sorted.compactMap { widgetConn in
            futureConnections.first { $0.id == widgetConn.id }
        }
        let leaveTimes = sortedConnections.map { calculateLeaveTime(for: $0) }

        let widgetData = WidgetData(
            transportType: transportType,
            connections: Array(sorted),
            leaveTimes: leaveTimes,
            updatedAt: Date()
        )
        AppGroupStorage.saveWidgetData(for: transportType, data: widgetData)
        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
    }

    private func handleError(_ error: Error) {
        errorMessage = (error as? GleisError)?.errorDescription ?? error.localizedDescription
        showError = true
        showToast("Error occurred", type: .error)
    }

    private func showToast(_ message: String, type: ToastView.ToastType) {
        toast = (message, type)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.toast = nil }
    }

    private func fetchConnectionsWithTimeout(
        from start: Station,
        to end: Station,
        count: Int = 5
    ) async throws -> [TrainConnection] {
        let fetchTask = Task.detached {
            try await self.transportService.fetchConnections(
                from: start,
                to: end,
                transportType: self.transportType,
                departureTime: Date(),
                count: count
            )
        }
        let timeoutTask = Task.detached {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            fetchTask.cancel()
        }
        do {
            let result = try await fetchTask.value
            timeoutTask.cancel()
            return result
        } catch is CancellationError {
            throw GleisError.networkError("Request timed out")
        }
    }
}
