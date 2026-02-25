import Combine
import Foundation
import WidgetKit

struct ConnectionRecoveryState: Identifiable {
    enum Kind {
        case missingSelection
        case updatedSelection
    }

    let id: String
    let kind: Kind
    let title: String
    let message: String
    let originalReminderId: String
    let suggestedConnection: TrainConnection?
}

@MainActor
final class TransportViewModel: ObservableObject {
    private static let widgetRetryTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    @Published var connections: LoadingState<[TrainConnection]> = .idle
    @Published var displayConnections: [DisplayConnection] = []
    @Published var stations: [Station] = []
    @Published var selectedConnection: TrainConnection?
    @Published var errorMessage: String?
    @Published var errorTitle: String?
    @Published var showError: Bool = false
    @Published var isShowingCachedData = false
    @Published private(set) var isRefreshingConnections = false
    @Published var isServiceDegraded = false
    @Published var serviceRetryAt: Date?
    @Published var lastUpdated: Date?
    @Published var isLoadingMore = false
    @Published var availableTrainTypes: [TrainType] = []
    @Published var connectionRecovery: ConnectionRecoveryState?

    let transportType: TransportType
    let toastManager = ToastManager()

    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let settingsManager: SettingsManager
    private let searchService: StationSearchService
    private let connectionCache = ConnectionCache.shared
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var currentFetchTask: Task<Void, Never>?
    private var lastFetchedRouteKey: String?
    private var lastInitializedFilterRouteKey: String?
    private var isFetching = false
    private var pendingRefreshRequest: (showFeedback: Bool, isUserInitiated: Bool)?
    private var isLoadingStations = false
    private var lastWidgetUpdate: Date?
    private var dismissedRecoverySignatures = Set<String>()
    private var reminderResyncSignatures = Set<String>()
    private var deliveredServiceAlertSignatures = Set<String>()
    private let minimumLiveRefreshInterval: TimeInterval = 45
    private let alertRetentionWindow: TimeInterval = 10 * 60
    private let alertClearConfirmationFetches = 2
    private var consecutiveAutomaticFetchFailures = 0
    private var automaticRefreshBackoffUntil: Date?
    private var alertStabilityByConnectionID: [String: AlertStabilityState] = [:]
    private var lastCommuteNotificationReconcileDay: Date?

    private struct AlertStabilityState {
        var activeAlerts: [ServiceAlert]
        var lastSeenAt: Date
        var consecutiveAuthoritativeNoAlertFetches: Int
    }

    var config: RouteConfiguration { settingsManager.config(for: transportType) }

    init(
        transportType: TransportType, transportService: TransportServiceProtocol = TransportService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        settingsManager: SettingsManager? = nil
    ) {
        self.transportType = transportType
        self.transportService = transportService
        self.notificationService = notificationService
        self.settingsManager = settingsManager ?? SettingsManager.shared
        searchService = StationSearchService(transportService: transportService)

        Task {
            await loadStations()
        }
        Task {
            await reconcileCommuteNotificationsIfNeeded(force: true)
        }
        observeConfigChanges()
    }

    private func observeConfigChanges() {
        // Watch for route-id changes (start/end station) - triggers refresh for external updates
        settingsManager.$trainCommuteConfig
            .map { ($0.startStation?.id, $0.endStation?.id) }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Immediately invalidate widget route snapshots to avoid showing the old station pair
                // while the new route fetch is still in progress.
                updateWidget(with: [], forceRefreshContexts: true)
                currentFetchTask?.cancel()
                currentFetchTask = Task { await self.refreshConnections(isUserInitiated: false) }
            }
            .store(in: &cancellables)

        // Watch for travel time/buffer time/filter changes - only updates display (no re-fetch needed)
        settingsManager.$trainCommuteConfig.dropFirst().removeDuplicates { old, new in
            old.stationTravelTimes == new.stationTravelTimes && old.stationBufferTimes == new.stationBufferTimes
                && old.excludedTrainTypes == new.excludedTrainTypes
        }.debounce(for: .milliseconds(100), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            rebuildDisplayConnections()
            if let loadedConnections = connections.value {
                updateWidgetIfNeeded(with: loadedConnections, forceRefreshContexts: true)
            }
        }.store(in: &cancellables)

        // Keep card selection state and widgets in sync when reminders are edited from
        // other views (Settings, repeat schedules, or background reminder resync).
        settingsManager.$scheduledReminders
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                rebuildDisplayConnections()
                if let loadedConnections = connections.value {
                    updateWidgetIfNeeded(with: loadedConnections, forceRefreshContexts: true)
                }
            }
            .store(in: &cancellables)

        settingsManager.$savedCommuteRoute
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                rebuildDisplayConnections()
                if let loadedConnections = connections.value {
                    updateWidgetIfNeeded(with: loadedConnections, forceRefreshContexts: true)
                }
            }
            .store(in: &cancellables)
    }

    func loadStations() async {
        guard !isLoadingStations else { return }
        isLoadingStations = true
        defer { isLoadingStations = false }
        do {
            stations = try await transportService.fetchStations(for: transportType)
        } catch {
            if !(error is CancellationError) { handleError(error) }
        }
    }

    func searchStations(_ query: String) async -> [Station] {
        await searchService.searchStations(query, transportType: transportType)
    }

    func refreshConnections(showFeedback: Bool = false, isUserInitiated: Bool = false) async {
        await reconcileCommuteNotificationsIfNeeded()

        guard !isFetching else {
            if let pending = pendingRefreshRequest {
                pendingRefreshRequest = (
                    showFeedback: pending.showFeedback || showFeedback,
                    isUserInitiated: pending.isUserInitiated || isUserInitiated
                )
            } else {
                pendingRefreshRequest = (showFeedback: showFeedback, isUserInitiated: isUserInitiated)
            }
            return
        }
        isFetching = true
        isRefreshingConnections = true
        defer {
            isFetching = false
            isRefreshingConnections = false
            if let pending = pendingRefreshRequest {
                pendingRefreshRequest = nil
                currentFetchTask = Task { @MainActor [weak self] in
                    await self?.refreshConnections(
                        showFeedback: pending.showFeedback,
                        isUserInitiated: pending.isUserInitiated
                    )
                }
            }
        }

        let currentConfig = config
        guard let start = currentConfig.startStation, let end = currentConfig.endStation, start.id != end.id else {
            connections = .idle
            isShowingCachedData = false
            clearServiceDegradedState()
            availableTrainTypes = []
            lastInitializedFilterRouteKey = nil
            connectionRecovery = nil
            updateWidget(with: [], forceRefreshContexts: true)
            return
        }

        let routeKey = "\(start.id)-\(end.id)"
        initializeFiltersIfNeeded(for: routeKey)
        var existingConnections: [TrainConnection]? = connections.value
        let isRouteChange = routeKey != lastFetchedRouteKey
        if isRouteChange {
            // A station swap should fetch and render its own route state.
            // Do not keep previous-route items around as fallback state.
            existingConnections = nil
        }
        if isRouteChange {
            deliveredServiceAlertSignatures.removeAll()
            alertStabilityByConnectionID.removeAll()
            clearServiceDegradedState()
        }

        if !isUserInitiated,
           let backoffUntil = automaticRefreshBackoffUntil,
           Date() < backoffUntil,
           !isRouteChange,
           let existing = existingConnections,
           !existing.isEmpty
        {
            isShowingCachedData = true
            markServiceDegradedState(retryAt: backoffUntil)
            updateWidgetIfNeeded(with: existing)
            return
        }

        // Skip fetch if route unchanged, already loaded, and not user-initiated
        // But still filter out past connections from existing state
        if !isUserInitiated, !isRouteChange, connections.isLoaded, !isShowingCachedData {
            if let existing = connections.value {
                let now = Date()
                let pinnedId = settingsManager.pinnedJourney?.connectionId
                let stillFuture = existing.filter { $0.departureTime > now || $0.id == pinnedId }
                if stillFuture.count != existing.count {
                    setConnections(stillFuture)
                    evaluateReminderReliability(with: stillFuture)
                    updateWidgetIfNeeded(with: stillFuture)
                }
                // If route data is complete and still fresh, skip network fetch.
                // Otherwise continue so service alerts and live status remain reliable.
                let routeDataIncomplete = stillFuture.contains(where: missingRouteData)
                let needsFreshNetworkData =
                    lastUpdated.map { now.timeIntervalSince($0) >= minimumLiveRefreshInterval } ?? true
                if !routeDataIncomplete, !needsFreshNetworkData { return }
            } else {
                return
            }
        }

        // Show cached route data immediately while we still attempt a live refresh.
        // This avoids blank/loading states during peak backend load.
        if existingConnections == nil,
           !isRouteChange,
           let cached = await connectionCache.load(for: transportType, from: start, to: end)
        {
            let futureCached = cached.filter { $0.departureTime > Date() }
            if !futureCached.isEmpty {
                lastFetchedRouteKey = routeKey
                setConnections(futureCached)
                evaluateReminderReliability(with: futureCached)
                isShowingCachedData = true
                lastUpdated = await connectionCache.lastUpdateTime(for: transportType, from: start, to: end)
                updateWidgetIfNeeded(with: futureCached)
                existingConnections = futureCached
            }
        }

        // Offline: use cached data
        if !NetworkMonitor.shared.isConnected,
           let cached = await connectionCache.load(for: transportType, from: start, to: end)
        {
            let futureConnections = cached.filter { $0.departureTime > Date() }
            guard !futureConnections.isEmpty else {
                connections = .error(.noConnectionsAvailable)
                return
            }
            lastFetchedRouteKey = routeKey
            setConnections(futureConnections)
            evaluateReminderReliability(with: futureConnections)
            isShowingCachedData = true
            clearServiceDegradedState()
            lastUpdated = await connectionCache.lastUpdateTime(for: transportType, from: start, to: end)
            updateWidgetIfNeeded(with: futureConnections)
            return
        }

        // Show loading skeleton whenever the route is transitioning, or when nothing is rendered yet.
        if existingConnections == nil {
            connections = .loading
            isShowingCachedData = false
            availableTrainTypes = []
        }

        do {
            let fetchCount = FetchLimits.connectionBatchSize
            let timeout = isUserInitiated ? 8.0 : 15.0
            let result = try await fetchConnectionsWithTimeout(
                from: start,
                to: end,
                count: fetchCount,
                timeoutSeconds: timeout
            )
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
            evaluateReminderReliability(with: merged)
            lastUpdated = Date()
            isShowingCachedData = false
            if showFeedback { toastManager.show("Updated", type: .success) }
            updateWidgetIfNeeded(with: merged)
            consecutiveAutomaticFetchFailures = 0
            automaticRefreshBackoffUntil = nil
            clearServiceDegradedState()
        } catch {
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            scheduleAutomaticRefreshBackoffIfNeeded(for: error, isUserInitiated: isUserInitiated)
            if let existing = existingConnections, !existing.isEmpty {
                if !(error is CancellationError) {
                    toastManager.show("Update failed, showing previous data", type: .info)
                }
                isShowingCachedData = true
                updateWidgetIfNeeded(with: existing)
                return
            }
            if let cached = await connectionCache.load(for: transportType, from: start, to: end) {
                let futureConnections = cached.filter { $0.departureTime > Date() }
                guard !futureConnections.isEmpty else {
                    connections = .error(.noConnectionsAvailable)
                    handleError(error)
                    return
                }
                lastFetchedRouteKey = routeKey
                setConnections(futureConnections)
                evaluateReminderReliability(with: futureConnections)
                isShowingCachedData = true
                lastUpdated = await connectionCache.lastUpdateTime(for: transportType, from: start, to: end)
                updateWidgetIfNeeded(with: futureConnections)
            } else {
                connections = .error(GleisError.from(error))
                connectionRecovery = nil
                handleError(error)
            }
        }
    }

    func scheduleNotification(for connection: TrainConnection, replacingReminderId: String? = nil) async {
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

            let createdAt =
                replacingReminderId.flatMap { id in
                    settingsManager.scheduledReminders.first(where: { $0.id == id })?.createdAt
                } ?? Date()
            let reminder = ScheduledReminder(
                id: connection.id, transportType: transportType, lineNumber: connection.lineNumber,
                destination: connection.arrivalStation.name, platform: connection.platform,
                departureTime: config.effectiveDepartureTime(for: connection),
                leaveTime: calculateLeaveTime(for: connection), delayMinutes: connection.delay, fiveMinuteWarning: true,
                exactTimeWarning: true, createdAt: createdAt
            )
            if let replacingReminderId, replacingReminderId != connection.id {
                notificationService.cancelNotification(id: "\(replacingReminderId)_fiveMinuteWarning")
                notificationService.cancelNotification(id: "\(replacingReminderId)_exactTime")
                notificationService.cancelServiceAlertNotifications(reminderId: replacingReminderId)
                settingsManager.removeReminder(connectionId: replacingReminderId)
            }
            settingsManager.upsertReminder(reminder)
            rebuildDisplayConnections()
            if case let .loaded(conns) = connections {
                updateWidgetIfNeeded(with: conns, forceRefreshContexts: true)
            }
        } catch {
            if let gleisError = error as? GleisError, case .notificationPermissionDenied = gleisError {
                do {
                    let granted = try await notificationService.requestAuthorization()
                    if granted {
                        await scheduleNotification(for: connection, replacingReminderId: replacingReminderId)
                    } else {
                        toastManager.show("Notifications permission required", type: .error)
                        errorMessage = "Enable notifications in Settings to receive reminders"
                        showError = true
                    }
                } catch { handleError(error) }
            } else {
                if let replacingReminderId, replacingReminderId != connection.id {
                    notificationService.cancelNotification(id: "\(connection.id)_fiveMinuteWarning")
                    notificationService.cancelNotification(id: "\(connection.id)_exactTime")
                }
                handleError(error)
            }
        }
    }

    func cancelNotification(for connection: TrainConnection) {
        notificationService.cancelNotification(id: "\(connection.id)_fiveMinuteWarning")
        notificationService.cancelNotification(id: "\(connection.id)_exactTime")
        notificationService.cancelServiceAlertNotifications(reminderId: connection.id)
        if selectedConnection?.id == connection.id { selectedConnection = nil }
        settingsManager.removeReminder(connectionId: connection.id)

        if let direction = settingsManager.savedCommuteRoute.matchesSchedule(connection),
           let weekday = Weekday(rawValue: Calendar.current.component(.weekday, from: connection.departureTime))
        {
            notificationService.cancelCommuteNotification(day: weekday, direction: direction)
            var route = settingsManager.savedCommuteRoute
            route.skipOccurrence(on: connection.departureTime, direction: direction)
            route.pruneOldSkippedDates()
            settingsManager.updateSavedCommuteRoute(route)
            toastManager.show("Skipped this trip", type: .info)
        } else {
            toastManager.show("Reminder cancelled", type: .info)
        }

        rebuildDisplayConnections()
        if case let .loaded(conns) = connections {
            updateWidgetIfNeeded(with: conns, forceRefreshContexts: true)
        }
    }

    func acceptConnectionRecovery() {
        guard let recovery = connectionRecovery else { return }
        guard let replacement = recovery.suggestedConnection else {
            dismissConnectionRecovery()
            return
        }
        Task {
            await scheduleNotification(
                for: replacement,
                replacingReminderId: recovery.originalReminderId
            )
        }
        connectionRecovery = nil
    }

    func dismissConnectionRecovery() {
        guard let signature = connectionRecovery?.id else { return }
        dismissedRecoverySignatures.insert(signature)
        connectionRecovery = nil
    }

    func calculateLeaveTime(for connection: TrainConnection) -> Date {
        config.leaveTime(for: connection, fromStationId: config.startStation?.id)
    }

    func pinJourney(for connection: TrainConnection) {
        settingsManager.pinJourney(connection)
        toastManager.show("Pinned as My Journey", type: .success)
        rebuildDisplayConnections()
        if case let .loaded(conns) = connections {
            updateWidgetIfNeeded(with: conns, forceRefreshContexts: true)
        }
    }

    func unpinJourney() {
        settingsManager.unpinJourney()
        toastManager.show("Unpinned journey", type: .info)
        rebuildDisplayConnections()
        if case let .loaded(conns) = connections {
            updateWidgetIfNeeded(with: conns, forceRefreshContexts: true)
        }
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

        let pageSize = FetchLimits.connectionBatchSize
        let maxPaginationHops = 3

        do {
            let currentIds = Set(current.map(\.id))
            var cursor = last.departureTime.addingTimeInterval(1)
            var appendedConnections: [TrainConnection] = []

            for _ in 0 ..< maxPaginationHops {
                let more = try await transportService.fetchConnections(
                    from: start, to: end, transportType: transportType, departureTime: cursor, count: pageSize
                )
                guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
                guard !more.isEmpty else { break }

                let now = Date()
                let unseen = more.filter { new in
                    new.departureTime > now && !currentIds.contains(new.id) && !appendedConnections.contains {
                        $0.id == new.id
                    }
                }
                if !unseen.isEmpty {
                    appendedConnections.append(contentsOf: unseen)
                    break
                }

                // Advance the cursor to avoid getting stuck on duplicate pages.
                if let furthestDeparture = more.map(\.departureTime).max(), furthestDeparture > cursor {
                    cursor = furthestDeparture.addingTimeInterval(1)
                } else {
                    break
                }

                // If backend returns fewer than requested, we've likely reached the end.
                if more.count < pageSize { break }
            }

            guard !appendedConnections.isEmpty else { return }
            setConnections(current + appendedConnections)
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
        pendingRefreshRequest = nil
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

        // Build available dynamic train types from API-derived connection data.
        var typesById: [String: TrainType] = [:]
        for connection in connections {
            let type = connection.trainType
            if let existing = typesById[type.id] {
                typesById[type.id] = existing.merged(with: type)
            } else {
                typesById[type.id] = type
            }
        }
        availableTrainTypes = typesById.values.sorted()

        let excluded = config.excludedTrainTypes
        let filtered = excluded.isEmpty ? connections : connections.filter { !excluded.contains($0.trainType) }
        let route = settingsManager.savedCommuteRoute

        let currentTime = Date()
        displayConnections = filtered.compactMap { connection in
            let leaveTime = calculateLeaveTime(for: connection)
            let isSelected =
                settingsManager.isReminderSet(for: connection.id)
                || hasActiveRepeatReminder(for: connection, route: route)
            let isPinned = settingsManager.isPinned(connection.id)

            return DisplayConnection(
                connection: connection, leaveTime: leaveTime, isSelected: isSelected, isPinned: isPinned,
                currentTime: currentTime
            )
        }
    }

    private func setConnections(_ newConnections: [TrainConnection]) {
        let previousConnections = connections.value ?? []
        let stabilizedConnections = stabilizedServiceAlerts(in: newConnections, previous: previousConnections)
        connections = .loaded(stabilizedConnections)
        rebuildDisplayConnections()
    }

    private func stabilizedServiceAlerts(
        in connections: [TrainConnection],
        previous: [TrainConnection]
    ) -> [TrainConnection] {
        let now = Date()
        alertStabilityByConnectionID = alertStabilityByConnectionID.filter {
            now.timeIntervalSince($0.value.lastSeenAt) <= alertRetentionWindow
        }
        let previousActiveByID = Dictionary(
            uniqueKeysWithValues: previous.compactMap { connection in
                let active = (connection.serviceAlerts ?? []).filter(\.isActive)
                return active.isEmpty ? nil : (connection.id, active)
            }
        )

        return connections.map { connection in
            let incomingAlerts = connection.serviceAlerts
            let incomingActive = (incomingAlerts ?? []).filter(\.isActive)

            if !incomingActive.isEmpty {
                alertStabilityByConnectionID[connection.id] = AlertStabilityState(
                    activeAlerts: incomingActive,
                    lastSeenAt: now,
                    consecutiveAuthoritativeNoAlertFetches: 0
                )
                return connection
            }

            let incomingIsAuthoritativeNoAlert = incomingAlerts != nil
            let priorState = alertStabilityByConnectionID[connection.id]
            let priorActiveAlerts = priorState?.activeAlerts ?? previousActiveByID[connection.id]
            guard let priorActiveAlerts, !priorActiveAlerts.isEmpty else { return connection }

            var updatedState = priorState
                ?? AlertStabilityState(
                    activeAlerts: priorActiveAlerts,
                    lastSeenAt: now,
                    consecutiveAuthoritativeNoAlertFetches: 0
                )
            updatedState.activeAlerts = priorActiveAlerts

            if incomingIsAuthoritativeNoAlert {
                updatedState.consecutiveAuthoritativeNoAlertFetches += 1
            } else {
                // Unknown payload (nil) should not clear known active alerts.
                updatedState.consecutiveAuthoritativeNoAlertFetches = 0
            }

            guard updatedState.consecutiveAuthoritativeNoAlertFetches < alertClearConfirmationFetches else {
                alertStabilityByConnectionID.removeValue(forKey: connection.id)
                return connection
            }

            updatedState.lastSeenAt = now
            alertStabilityByConnectionID[connection.id] = updatedState
            return copyConnection(connection, withServiceAlerts: priorActiveAlerts)
        }
    }

    private func copyConnection(_ connection: TrainConnection, withServiceAlerts alerts: [ServiceAlert]?) -> TrainConnection {
        TrainConnection(
            id: connection.id,
            lineNumber: connection.lineNumber,
            trainType: connection.trainType,
            lineColors: connection.lineColors,
            departureTime: connection.departureTime,
            arrivalTime: connection.arrivalTime,
            departureStation: connection.departureStation,
            arrivalStation: connection.arrivalStation,
            platform: connection.platform,
            delay: connection.delay,
            status: connection.status,
            transfers: connection.transfers,
            legs: connection.legs,
            serviceAlerts: alerts
        )
    }

    // MARK: - Widget

    private func updateWidgetIfNeeded(with connections: [TrainConnection], forceRefreshContexts: Bool = false) {
        let now = Date()
        if !forceRefreshContexts,
           let lastUpdate = lastWidgetUpdate,
           now.timeIntervalSince(lastUpdate) < 5
        {
            return
        }
        lastWidgetUpdate = now
        updateWidget(with: connections, forceRefreshContexts: forceRefreshContexts)
    }

    private func updateWidget(with connections: [TrainConnection], forceRefreshContexts: Bool = false) {
        let now = Date()
        let futureConnections = connections.filter { $0.departureTime > now }
        let route = settingsManager.savedCommuteRoute

        let widgetConnections = futureConnections.map { conn -> WidgetConnection in
            let stopCount = conn.legs.first { !$0.isWalking }?.stopCount
            let hasReminder =
                settingsManager.isReminderSet(for: conn.id)
                || hasActiveRepeatReminder(for: conn, route: route)
            let isPinned = settingsManager.isPinned(conn.id)
            return WidgetConnection(
                id: conn.id, lineNumber: conn.lineNumber, lineColors: conn.lineColors, departureTime: conn.departureTime,
                arrivalTime: conn.arrivalTime, destination: conn.arrivalStation.name, platform: conn.platform,
                transfers: conn.transfers, delay: conn.delay, stopCount: stopCount, hasReminder: hasReminder,
                isPinned: isPinned,
                hasServiceAlert: (conn.serviceAlerts ?? []).contains(where: \.isActive)
            )
        }

        let sorted = widgetConnections.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.hasReminder != rhs.hasReminder { return lhs.hasReminder }
            return lhs.departureTime < rhs.departureTime
        }
        let topConnections = Array(sorted.prefix(3))

        let sortedConnections = topConnections.compactMap {
            widgetConn in futureConnections.first { $0.id == widgetConn.id }
        }
        let leaveTimes = sortedConnections.map { calculateLeaveTime(for: $0) }
        let isRouteConfigured = config.startStation != nil && config.endStation != nil
        let state: WidgetDataState
        let message: String?
        if topConnections.isEmpty {
            state = .stale
            message = "No upcoming departures."
        } else if isServiceDegraded, isShowingCachedData {
            state = .fallback
            message = widgetServiceDegradedMessage(referenceDate: now)
        } else {
            state = .fresh
            message = nil
        }
        let action: WidgetRecoveryAction = isRouteConfigured ? .openLiveRoute : .openSetup

        let widgetData = WidgetData(
            transportType: transportType,
            connections: topConnections,
            leaveTimes: leaveTimes,
            fromStationName: config.startStation?.name,
            toStationName: config.endStation?.name,
            updatedAt: Date(),
            state: state,
            stateMessage: message,
            recoveryAction: action
        )
        AppGroupStorage.saveWidgetData(for: transportType, data: widgetData)
        // Keep all intent-keyed widget variants (direction/day/route) fresh as well.
        Task(priority: .utility) {
            await WidgetRefreshService.shared.refreshWidgetData(force: forceRefreshContexts)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
    }

    // MARK: - Reminder Reliability

    private func evaluateReminderReliability(with liveConnections: [TrainConnection]) {
        let now = Date()
        let relevantReminders = settingsManager.scheduledReminders
            .filter { reminder in
                reminder.transportType == transportType
                    && reminder.departureTime > now.addingTimeInterval(-15 * 60)
            }
            .sorted { $0.departureTime < $1.departureTime }

        notifyServiceAlertsForReminders(relevantReminders, liveConnections: liveConnections)

        guard !relevantReminders.isEmpty else {
            connectionRecovery = nil
            return
        }

        let liveConnectionsById = Dictionary(uniqueKeysWithValues: liveConnections.map { ($0.id, $0) })

        for reminder in relevantReminders {
            if let liveConnection = liveConnectionsById[reminder.id] {
                guard shouldPromptForLiveUpdate(reminder: reminder, liveConnection: liveConnection, now: now) else {
                    continue
                }
                let signature = recoverySignature(reminder: reminder, suggestedConnectionId: liveConnection.id)
                if dismissedRecoverySignatures.contains(signature) { continue }

                connectionRecovery = ConnectionRecoveryState(
                    id: signature,
                    kind: .updatedSelection,
                    title: "Your train changed",
                    message: recoveryMessageForUpdate(reminder: reminder, liveConnection: liveConnection),
                    originalReminderId: reminder.id,
                    suggestedConnection: liveConnection
                )

                resyncReminderIfNeeded(reminder: reminder, with: liveConnection, signature: signature)
                return
            }

            guard reminder.departureTime > now else { continue }
            let replacement = bestReplacementConnection(for: reminder, in: liveConnections, now: now)
            let signature = recoverySignature(reminder: reminder, suggestedConnectionId: replacement?.id)
            if dismissedRecoverySignatures.contains(signature) { continue }

            connectionRecovery = ConnectionRecoveryState(
                id: signature,
                kind: .missingSelection,
                title: "Selected train unavailable",
                message: recoveryMessageForMissing(reminder: reminder, replacement: replacement),
                originalReminderId: reminder.id,
                suggestedConnection: replacement
            )
            return
        }

        connectionRecovery = nil
    }

    private func reconcileCommuteNotificationsIfNeeded(force: Bool = false) async {
        let today = Calendar.current.startOfDay(for: Date())
        if !force,
           let lastReconcile = lastCommuteNotificationReconcileDay,
           Calendar.current.isDate(lastReconcile, inSameDayAs: today)
        {
            return
        }
        await reconcileCommuteNotificationsWithSavedRoute(referenceDate: today)
        lastCommuteNotificationReconcileDay = today
    }

    private func reconcileCommuteNotificationsWithSavedRoute(referenceDate: Date) async {
        var route = settingsManager.savedCommuteRoute
        let routeBeforePrune = route
        route.pruneOldSkippedDates()
        if route != routeBeforePrune {
            settingsManager.updateSavedCommuteRoute(route)
        }

        let calendar = Calendar.current
        let skippedTodayGlobally = route.skippedDates.contains { calendar.isDate($0, inSameDayAs: referenceDate) }
        let todayWeekday = Weekday(rawValue: calendar.component(.weekday, from: referenceDate))

        notificationService.cancelAllCommuteNotifications()
        let cfg = config

        for (day, schedule) in route.toWorkSchedules where route.isDayActive(day, direction: .toWork) {
            if day == todayWeekday,
               (skippedTodayGlobally || route.isOccurrenceSkipped(on: referenceDate, direction: .toWork))
            {
                continue
            }
            try? await notificationService.scheduleCommuteNotification(
                route: route, day: day, schedule: schedule, direction: .toWork, config: cfg
            )
        }

        for (day, schedule) in route.toHomeSchedules where route.isDayActive(day, direction: .toHome) {
            if day == todayWeekday,
               (skippedTodayGlobally || route.isOccurrenceSkipped(on: referenceDate, direction: .toHome))
            {
                continue
            }
            try? await notificationService.scheduleCommuteNotification(
                route: route, day: day, schedule: schedule, direction: .toHome, config: cfg
            )
        }
    }

    private func hasActiveRepeatReminder(for connection: TrainConnection, route: SavedCommuteRoute) -> Bool {
        guard let direction = route.matchesSchedule(connection) else { return false }
        let calendar = Calendar.current
        let connectionDay = calendar.startOfDay(for: connection.departureTime)
        if route.skippedDates.contains(where: { calendar.isDate($0, inSameDayAs: connectionDay) }) { return false }
        return !route.isOccurrenceSkipped(on: connectionDay, direction: direction)
    }

    private func notifyServiceAlertsForReminders(
        _ reminders: [ScheduledReminder],
        liveConnections: [TrainConnection]
    ) {
        guard !reminders.isEmpty else {
            deliveredServiceAlertSignatures.removeAll()
            return
        }
        let liveConnectionsById = Dictionary(uniqueKeysWithValues: liveConnections.map { ($0.id, $0) })
        var activeSignatures = Set<String>()

        for reminder in reminders where reminder.fiveMinuteWarning || reminder.exactTimeWarning {
            guard let liveConnection = liveConnectionsById[reminder.id] else { continue }
            let activeAlerts = (liveConnection.serviceAlerts ?? []).filter(\.isActive)
            guard !activeAlerts.isEmpty else { continue }

            for alert in activeAlerts {
                let signature = serviceAlertSignature(reminderId: reminder.id, alert: alert)
                activeSignatures.insert(signature)
                guard !deliveredServiceAlertSignatures.contains(signature) else { continue }
                deliveredServiceAlertSignatures.insert(signature)

                Task {
                    try? await notificationService.scheduleServiceAlertNotification(
                        for: liveConnection,
                        alert: alert,
                        reminderId: reminder.id
                    )
                }
            }
        }

        // Keep dedupe state bounded to currently relevant reminders/alerts.
        deliveredServiceAlertSignatures = deliveredServiceAlertSignatures.intersection(activeSignatures)
    }

    private func serviceAlertSignature(reminderId: String, alert: ServiceAlert) -> String {
        let startStamp = alert.startsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let endStamp = alert.endsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(reminderId)|\(alert.id)|\(alert.priority)|\(startStamp)|\(endStamp)|\(stableAlertHash(alert.title))|\(stableAlertHash(alert.message))"
    }

    private func stableAlertHash(_ value: String) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    private func shouldPromptForLiveUpdate(
        reminder: ScheduledReminder,
        liveConnection: TrainConnection,
        now: Date
    ) -> Bool {
        let leaveTime = calculateLeaveTime(for: liveConnection)
        guard leaveTime > now else { return false }

        // Only surface resuggest prompts when this commute is close enough to matter.
        let isNearLeaveWindow = leaveTime.timeIntervalSince(now) <= 90 * 60
        guard isNearLeaveWindow else { return false }

        let normalizedReminderPlatform = normalizePlatform(reminder.platform)
        let normalizedLivePlatform = normalizePlatform(liveConnection.platform)
        let platformChanged = normalizedReminderPlatform != normalizedLivePlatform
        let delayChanged = reminder.delayMinutes != liveConnection.delay
        let departureShifted = abs(liveConnection.departureTime.timeIntervalSince(reminder.departureTime)) >= 60
        return platformChanged || delayChanged || departureShifted
    }

    private func bestReplacementConnection(
        for reminder: ScheduledReminder,
        in connections: [TrainConnection],
        now: Date
    ) -> TrainConnection? {
        let futureConnections = connections.filter { $0.departureTime > now }
        guard !futureConnections.isEmpty else { return nil }

        let normalizedReminderLine = normalizeLine(reminder.lineNumber)
        let sameLine = futureConnections.filter { normalizeLine($0.lineNumber) == normalizedReminderLine }
        if let closestSameLine = sameLine.min(by: {
            abs($0.departureTime.timeIntervalSince(reminder.departureTime))
                < abs($1.departureTime.timeIntervalSince(reminder.departureTime))
        }) {
            return closestSameLine
        }

        return futureConnections.min { $0.departureTime < $1.departureTime }
    }

    private func recoverySignature(reminder: ScheduledReminder, suggestedConnectionId: String?) -> String {
        "recovery_\(reminder.id)_\(suggestedConnectionId ?? "none")"
    }

    private func recoveryMessageForMissing(
        reminder: ScheduledReminder,
        replacement: TrainConnection?
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let originalTime = formatter.string(from: reminder.departureTime)
        if let replacement {
            let replacementTime = formatter.string(from: replacement.departureTime)
            return "\(reminder.lineNumber) at \(originalTime) is no longer running. Try \(replacement.lineNumber) at \(replacementTime)."
        }
        return "\(reminder.lineNumber) at \(originalTime) is no longer running. Open the list and choose a replacement."
    }

    private func recoveryMessageForUpdate(
        reminder: ScheduledReminder,
        liveConnection: TrainConnection
    ) -> String {
        var parts: [String] = []
        if reminder.delayMinutes != liveConnection.delay {
            parts.append("delay is now \(liveConnection.delay) min")
        }
        if normalizePlatform(reminder.platform) != normalizePlatform(liveConnection.platform),
           let platform = liveConnection.platform, !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            parts.append("platform changed to \(platform)")
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if abs(liveConnection.departureTime.timeIntervalSince(reminder.departureTime)) >= 60 {
            parts.append("departs at \(formatter.string(from: liveConnection.departureTime))")
        }

        if parts.isEmpty {
            return "Live train data changed. Re-apply your reminder to stay synced."
        }
        return parts.joined(separator: ", ") + "."
    }

    private func resyncReminderIfNeeded(
        reminder: ScheduledReminder,
        with liveConnection: TrainConnection,
        signature: String
    ) {
        guard !reminderResyncSignatures.contains(signature) else { return }
        reminderResyncSignatures.insert(signature)

        Task {
            let fromStationId = config.startStation?.id

            do {
                try await notificationService.scheduleNotification(
                    for: liveConnection,
                    config: config,
                    type: .fiveMinuteWarning,
                    fromStationId: fromStationId
                )
                try await notificationService.scheduleNotification(
                    for: liveConnection,
                    config: config,
                    type: .exactTime,
                    fromStationId: fromStationId
                )

                let updatedReminder = ScheduledReminder(
                    id: liveConnection.id,
                    transportType: transportType,
                    lineNumber: liveConnection.lineNumber,
                    destination: liveConnection.arrivalStation.name,
                    platform: liveConnection.platform,
                    departureTime: config.effectiveDepartureTime(for: liveConnection),
                    leaveTime: calculateLeaveTime(for: liveConnection),
                    delayMinutes: liveConnection.delay,
                    fiveMinuteWarning: true,
                    exactTimeWarning: true,
                    createdAt: reminder.createdAt
                )

                if reminder.id != updatedReminder.id {
                    notificationService.cancelNotification(id: "\(reminder.id)_fiveMinuteWarning")
                    notificationService.cancelNotification(id: "\(reminder.id)_exactTime")
                    notificationService.cancelServiceAlertNotifications(reminderId: reminder.id)
                    settingsManager.removeReminder(connectionId: reminder.id)
                }
                settingsManager.upsertReminder(updatedReminder)
                rebuildDisplayConnections()
                if case let .loaded(conns) = connections {
                    updateWidgetIfNeeded(with: conns, forceRefreshContexts: true)
                }
            } catch {
                // Keep current reminder if live resync fails and allow a retry on next refresh.
                if reminder.id != liveConnection.id {
                    notificationService.cancelNotification(id: "\(liveConnection.id)_fiveMinuteWarning")
                    notificationService.cancelNotification(id: "\(liveConnection.id)_exactTime")
                    notificationService.cancelServiceAlertNotifications(reminderId: liveConnection.id)
                }
                reminderResyncSignatures.remove(signature)
            }
        }
    }

    private func normalizeLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private func normalizePlatform(_ platform: String?) -> String {
        (platform ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    // MARK: - Error Handling

    private func missingRouteDetails(_ connection: TrainConnection) -> Bool {
        connection.legs.contains { leg in
            !leg.isWalking && (
                leg.stopCount == nil
                    || ((leg.stopCount ?? 0) > 0 && leg.intermediateStops.isEmpty)
            )
        }
    }

    private func missingRouteData(_ connection: TrainConnection) -> Bool {
        missingRouteDetails(connection) || connection.serviceAlerts == nil
    }

    private func handleError(_ error: Error) {
        let mapped = GleisError.from(error)
        errorTitle = mapped.userFacingTitle
        errorMessage = mapped.userFacingMessage
        showError = true
        toastManager.show(mapped.userFacingTitle, type: .error)
    }

    private func fetchConnectionsWithTimeout(
        from start: Station,
        to end: Station,
        count: Int = FetchLimits.connectionBatchSize,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> [TrainConnection] {
        let service = transportService
        let type = transportType
        final class CompletionState {
            private let lock = NSLock()
            private var didComplete = false

            func resumeOnce(
                _ result: Result<[TrainConnection], Error>,
                continuation: CheckedContinuation<[TrainConnection], Error>
            ) {
                lock.lock()
                defer { lock.unlock() }
                guard !didComplete else { return }
                didComplete = true
                continuation.resume(with: result)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = CompletionState()

            let fetchTask = Task {
                do {
                    let value = try await service.fetchConnections(
                        from: start, to: end, transportType: type, departureTime: Date(), count: count
                    )
                    completion.resumeOnce(.success(value), continuation: continuation)
                } catch {
                    guard !(error is CancellationError) else { return }
                    completion.resumeOnce(.failure(error), continuation: continuation)
                }
            }

            Task {
                let clampedTimeout = max(1.0, timeoutSeconds)
                let nanos = UInt64(clampedTimeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                fetchTask.cancel()
                completion.resumeOnce(.failure(GleisError.networkError("Request timed out")), continuation: continuation)
            }
        }
    }

    private func scheduleAutomaticRefreshBackoffIfNeeded(for error: Error, isUserInitiated: Bool) {
        guard isLikelyOverloadError(error) else {
            consecutiveAutomaticFetchFailures = 0
            automaticRefreshBackoffUntil = nil
            clearServiceDegradedState()
            return
        }

        if isUserInitiated {
            let retryAt = automaticRefreshBackoffUntil ?? Date().addingTimeInterval(20)
            markServiceDegradedState(retryAt: retryAt)
            return
        }

        consecutiveAutomaticFetchFailures += 1
        let attempt = max(0, consecutiveAutomaticFetchFailures - 1)
        let waitSeconds = min(240.0, 20.0 * pow(2.0, Double(attempt)))
        let retryAt = Date().addingTimeInterval(waitSeconds)
        automaticRefreshBackoffUntil = retryAt
        markServiceDegradedState(retryAt: retryAt)
    }

    private func isLikelyOverloadError(_ error: Error) -> Bool {
        GleisError.from(error).isTransientOverload
    }

    private func initializeFiltersIfNeeded(for routeKey: String) {
        guard lastInitializedFilterRouteKey != routeKey else { return }
        lastInitializedFilterRouteKey = routeKey
        guard !config.excludedTrainTypes.isEmpty else { return }
        var updated = config
        updated.excludedTrainTypes = []
        settingsManager.updateConfig(updated)
    }

    private func markServiceDegradedState(retryAt: Date?) {
        isServiceDegraded = true
        serviceRetryAt = retryAt
    }

    private func clearServiceDegradedState() {
        isServiceDegraded = false
        serviceRetryAt = nil
    }

    private func widgetServiceDegradedMessage(referenceDate: Date) -> String {
        guard let retryAt = serviceRetryAt else {
            return "Live data delayed. Showing cached departures."
        }
        if retryAt <= referenceDate {
            return "Live data delayed. Retrying now."
        }
        return "Live data delayed. Retry around \(Self.widgetRetryTimeFormatter.string(from: retryAt))."
    }
}
