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
    private var lastWidgetSnapshotSignature: String?
    private var widgetCoverageTopUpTask: Task<Void, Never>?
    private var lastWidgetCoverageTopUpAttemptAt: Date?
    private var paginationRouteKey: String?
    private var paginationSeedDateTime: Date?
    private var forwardPaginationCursor: String?
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
    private let widgetStoredConnectionLimit = 60
    private let widgetTopUpBatchSize = FetchLimits.connectionBatchSize
    private let widgetTopUpMinimumInterval: TimeInterval = 10 * 60

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
                resetWidgetSyncStateForRouteChange()
                updateWidget(with: [])
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
            refreshDisplayAndWidgetSelectionState()
        }.store(in: &cancellables)

        // Keep card selection state and widgets in sync when reminders are edited from
        // other views (Settings, repeat schedules, or background reminder resync).
        settingsManager.$scheduledReminders
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                refreshDisplayAndWidgetSelectionState()
            }
            .store(in: &cancellables)

        settingsManager.$savedCommuteRoute
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                refreshDisplayAndWidgetSelectionState()
            }
            .store(in: &cancellables)
    }

    private func refreshDisplayAndWidgetSelectionState() {
        rebuildDisplayConnections()
        refreshWidgetsFromLoadedConnections()
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
            resetPaginationState()
            availableTrainTypes = []
            lastInitializedFilterRouteKey = nil
            connectionRecovery = nil
            resetWidgetSyncStateForRouteChange()
            updateWidget(with: [])
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
            resetPaginationState()
            resetWidgetSyncStateForRouteChange()
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
                resetPaginationState()
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
            resetPaginationState()
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
            let requestSeedDateTime = Date()
            let page = try await fetchConnectionsPageWithTimeout(
                from: start,
                to: end,
                seedDateTime: requestSeedDateTime,
                pageSize: fetchCount,
                timeoutSeconds: timeout
            )
            let result = page.connections
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
            paginationRouteKey = routeKey
            paginationSeedDateTime = requestSeedDateTime
            forwardPaginationCursor = page.forwardCursor
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
                resetPaginationState()
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
            refreshWidgetsFromLoadedConnections()
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
        refreshWidgetsFromLoadedConnections()
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
        refreshWidgetsFromLoadedConnections()
    }

    func unpinJourney() {
        settingsManager.unpinJourney()
        toastManager.show("Unpinned journey", type: .info)
        rebuildDisplayConnections()
        refreshWidgetsFromLoadedConnections()
    }

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
            let now = Date()
            let routeKey = "\(start.id)-\(end.id)"
            var seenIds = Set(current.map(\.id))
            var appendedConnections: [TrainConnection] = []
            var nextCursor: String? =
                paginationRouteKey == routeKey
                    ? forwardPaginationCursor : nil
            let seedDateTime = paginationSeedDateTime ?? Date()
            var canUseCursorPagination = nextCursor != nil

            if canUseCursorPagination {
                for _ in 0 ..< maxPaginationHops {
                    guard let cursorToken = nextCursor else { break }
                    let page = try await transportService.fetchConnectionsPage(
                        from: start,
                        to: end,
                        transportType: transportType,
                        seedDateTime: seedDateTime,
                        pageSize: pageSize,
                        cursor: cursorToken
                    )
                    guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
                    let more = page.connections

                    for connection in more where connection.departureTime > now {
                        if seenIds.insert(connection.id).inserted {
                            appendedConnections.append(connection)
                        }
                    }

                    let upcomingCursor = page.forwardCursor
                    guard let upcomingCursor, upcomingCursor != cursorToken else {
                        nextCursor = nil
                        break
                    }

                    nextCursor = upcomingCursor
                    if appendedConnections.count >= pageSize || more.count < pageSize { break }
                }
            }

            if appendedConnections.isEmpty {
                canUseCursorPagination = false
            }

            if !canUseCursorPagination {
                var departureCursor = last.departureTime.addingTimeInterval(1)
                for _ in 0 ..< maxPaginationHops {
                    let more = try await transportService.fetchConnections(
                        from: start,
                        to: end,
                        transportType: transportType,
                        departureTime: departureCursor,
                        count: pageSize
                    )
                    guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
                    guard !more.isEmpty else { break }

                    for connection in more where connection.departureTime > now {
                        if seenIds.insert(connection.id).inserted {
                            appendedConnections.append(connection)
                        }
                    }

                    if let furthestDeparture = more.map(\.departureTime).max(), furthestDeparture > departureCursor {
                        departureCursor = furthestDeparture.addingTimeInterval(1)
                    } else {
                        break
                    }

                    if !appendedConnections.isEmpty || more.count < pageSize { break }
                }
            }

            if paginationRouteKey == routeKey {
                forwardPaginationCursor = nextCursor
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

    func setImmediateRouteTransitionState(start: Station?, end: Station?) {
        let hasValidRoute = start != nil && end != nil && start?.id != end?.id
        connections = hasValidRoute ? .loading : .idle
        displayConnections = []
        availableTrainTypes = []
        resetPaginationState()
        isShowingCachedData = false
        connectionRecovery = nil
        if !hasValidRoute {
            clearServiceDegradedState()
            resetWidgetSyncStateForRouteChange()
            updateWidget(with: [])
        }
    }

    deinit {
        refreshTimer?.invalidate()
        displayTimer?.invalidate()
        currentFetchTask?.cancel()
        widgetCoverageTopUpTask?.cancel()
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
                || route.hasActiveReminder(for: connection)
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
        let deduplicatedConnections = deduplicatedConnections(stabilizedConnections, previous: previousConnections)
        connections = .loaded(deduplicatedConnections)
        rebuildDisplayConnections()
    }

    private func deduplicatedConnections(
        _ connections: [TrainConnection],
        previous: [TrainConnection]
    ) -> [TrainConnection] {
        guard connections.count > 1 else { return connections }

        let previousIds = Set(previous.map(\.id))
        var bestBySignature: [String: TrainConnection] = [:]

        for connection in connections {
            let signature = connectionSignature(for: connection)
            guard let existing = bestBySignature[signature] else {
                bestBySignature[signature] = connection
                continue
            }

            if shouldPrefer(connection, over: existing, previousIds: previousIds) {
                bestBySignature[signature] = connection
            }
        }

        return bestBySignature.values.sorted { lhs, rhs in
            if lhs.departureTime != rhs.departureTime {
                return lhs.departureTime < rhs.departureTime
            }
            if lhs.arrivalTime != rhs.arrivalTime {
                return lhs.arrivalTime < rhs.arrivalTime
            }
            return lhs.id < rhs.id
        }
    }

    private func connectionSignature(for connection: TrainConnection) -> String {
        let legSignature = connection.legs.map(connectionLegSignature).joined(separator: ";")
        return [
            connection.departureStation.id,
            connection.arrivalStation.id,
            minuteTimestamp(connection.departureTime),
            minuteTimestamp(connection.arrivalTime),
            "\(connection.transfers)",
            legSignature,
        ].joined(separator: "|")
    }

    private func connectionLegSignature(_ leg: ConnectionLeg) -> String {
        [
            leg.isWalking ? "W" : "T",
            normalizeLine(leg.lineNumber),
            leg.from.id,
            leg.to.id,
            minuteTimestamp(leg.departureTime),
            minuteTimestamp(leg.arrivalTime),
        ].joined(separator: "~")
    }

    private func minuteTimestamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return String(Int(date.timeIntervalSince1970 / 60))
    }

    private func shouldPrefer(
        _ candidate: TrainConnection,
        over current: TrainConnection,
        previousIds: Set<String>
    ) -> Bool {
        let candidateScore = preferenceScore(for: candidate, previousIds: previousIds)
        let currentScore = preferenceScore(for: current, previousIds: previousIds)
        if candidateScore != currentScore {
            return candidateScore > currentScore
        }
        return candidate.id < current.id
    }

    private func preferenceScore(for connection: TrainConnection, previousIds: Set<String>) -> Int {
        var score = 0

        let route = settingsManager.savedCommuteRoute
        if settingsManager.isPinned(connection.id) { score += 1_000 }
        if settingsManager.isReminderSet(for: connection.id) || route.hasActiveReminder(for: connection) {
            score += 800
        }
        if previousIds.contains(connection.id) { score += 300 }
        if connection.serviceAlerts != nil { score += 80 }
        score += (connection.serviceAlerts ?? []).filter(\.isActive).count * 40
        if !normalizePlatform(connection.platform).isEmpty { score += 2 }

        score += connection.legs.reduce(0) { partial, leg in
            var legScore = 0
            if !leg.isWalking { legScore += 10 }
            if leg.stopCount != nil { legScore += 5 }
            if !leg.intermediateStops.isEmpty { legScore += 5 }
            if !normalizePlatform(leg.platform).isEmpty { legScore += 2 }
            return partial + legScore
        }

        return score
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

    private func refreshWidgetsFromLoadedConnections() {
        guard case let .loaded(loadedConnections) = connections else { return }
        updateWidgetIfNeeded(with: loadedConnections)
    }

    private func updateWidgetIfNeeded(with connections: [TrainConnection], scheduleCoverageTopUp: Bool = true) {
        let now = Date()
        if scheduleCoverageTopUp {
            scheduleWidgetCoverageTopUpIfNeeded(from: connections, referenceDate: now)
        }
        let signature = widgetSnapshotSignature(from: connections, at: now)
        if signature == lastWidgetSnapshotSignature {
            WidgetSyncDiagnostics.snapshotWriteSkipped(
                reason: "signature_unchanged",
                routeSignature: widgetRouteSignature(),
                snapshotSignature: signature
            )
            return
        }

        updateWidget(with: connections, referenceDate: now, snapshotSignature: signature)
    }

    private func widgetRouteSignature() -> String {
        WidgetSnapshotBuilder.routeSignature(
            startStationId: config.startStation?.id,
            endStationId: config.endStation?.id
        )
    }

    private func widgetSnapshotSignature(from connections: [TrainConnection], at now: Date) -> String {
        let routeSignature = widgetRouteSignature()
        let stateSignature = (isServiceDegraded && isShowingCachedData) ? "fallback" : "fresh"
        let candidates = widgetSnapshotCandidates(from: connections, at: now)
        let coverage = WidgetSnapshotBuilder.coverageRange(for: candidates, fallback: now)
        return WidgetSnapshotBuilder.snapshotSignature(
            routeSignature: routeSignature,
            stateSignature: stateSignature,
            candidates: candidates,
            coverageRange: coverage
        )
    }

    private func updateWidget(
        with connections: [TrainConnection],
        referenceDate now: Date = Date(),
        snapshotSignature: String? = nil
    ) {
        let candidates = widgetSnapshotCandidates(from: connections, at: now)
        let storedConnections = candidates.map(WidgetSnapshotBuilder.makeWidgetConnection)
        let leaveTimes = candidates.map(\.leaveTime)
        let routeSignature = widgetRouteSignature()
        let coverageRange = WidgetSnapshotBuilder.coverageRange(for: candidates, fallback: now)
        let computedSnapshotSignature = snapshotSignature ?? widgetSnapshotSignature(from: connections, at: now)
        let isRouteConfigured = config.startStation != nil && config.endStation != nil
        let state: WidgetDataState
        let message: String?
        if !isRouteConfigured {
            state = .fresh
            message = "Set up your route to see departures."
        } else if storedConnections.isEmpty {
            state = .fresh
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
            connections: storedConnections,
            leaveTimes: leaveTimes,
            fromStationName: config.startStation?.name,
            toStationName: config.endStation?.name,
            updatedAt: now,
            generatedAt: now,
            coverageStart: coverageRange.start,
            coverageEnd: coverageRange.end,
            routeSignature: routeSignature,
            snapshotSignature: computedSnapshotSignature,
            state: state,
            stateMessage: message,
            recoveryAction: action
        )
        lastWidgetSnapshotSignature = computedSnapshotSignature
        AppGroupStorage.savePrimaryWidgetData(for: transportType, data: widgetData)
        WidgetSyncDiagnostics.snapshotWriteApplied(
            reason: "transport_view_model",
            routeSignature: routeSignature,
            snapshotSignature: computedSnapshotSignature,
            connectionCount: storedConnections.count,
            coverageStart: coverageRange.start,
            coverageEnd: coverageRange.end,
            state: state.rawValue
        )
        WidgetSyncDiagnostics.timelineReloadTriggered(reason: "transport_view_model_write")
        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
    }

    private func widgetSnapshotCandidates(
        from sourceConnections: [TrainConnection],
        at now: Date
    ) -> [WidgetSnapshotCandidate] {
        let reminderIds = Set(settingsManager.scheduledReminders.map(\.id))
        return WidgetSnapshotBuilder.selectCandidates(
            from: sourceConnections,
            config: config,
            savedRoute: settingsManager.savedCommuteRoute,
            reminderIds: reminderIds,
            pinnedConnectionId: settingsManager.pinnedJourney?.connectionId,
            referenceDate: now,
            limit: widgetStoredConnectionLimit
        )
    }

    private func upcomingMorningCoverageWindow(from referenceDate: Date) -> (start: Date, end: Date) {
        WidgetSnapshotBuilder.morningCoverageWindow(from: referenceDate)
    }

    private func scheduleWidgetCoverageTopUpIfNeeded(
        from sourceConnections: [TrainConnection],
        referenceDate: Date
    ) {
        guard let start = config.startStation, let end = config.endStation, start.id != end.id else {
            widgetCoverageTopUpTask?.cancel()
            widgetCoverageTopUpTask = nil
            return
        }
        guard widgetCoverageTopUpTask == nil else { return }
        if let lastAttempt = lastWidgetCoverageTopUpAttemptAt,
           referenceDate.timeIntervalSince(lastAttempt) < widgetTopUpMinimumInterval
        {
            return
        }

        let morningWindow = upcomingMorningCoverageWindow(from: referenceDate)
        let hoursUntilWindowEnd = morningWindow.end.timeIntervalSince(referenceDate)
        guard hoursUntilWindowEnd > 0, hoursUntilWindowEnd <= 12 * 60 * 60 else { return }

        let routeSignature = widgetRouteSignature()
        if let stored = AppGroupStorage.loadPrimaryWidgetData(for: transportType),
           stored.routeSignature == routeSignature,
           !stored.needsTopUp(referenceDate: referenceDate, targetEnd: morningWindow.end)
        {
            WidgetSyncDiagnostics.coverageDecision(
                reason: "topup_not_needed_stored_coverage",
                referenceDate: referenceDate,
                coverageEnd: stored.coverageEnd,
                targetEnd: morningWindow.end,
                futureCount: stored.futureConnections(from: referenceDate).count
            )
            return
        }

        let candidates = widgetSnapshotCandidates(from: sourceConnections, at: referenceDate)
        let baselineCoverage = WidgetSnapshotBuilder.coverageRange(for: candidates, fallback: referenceDate)
        let baselineWidgetData = WidgetData(
            transportType: transportType,
            connections: candidates.map(WidgetSnapshotBuilder.makeWidgetConnection),
            leaveTimes: candidates.map(\.leaveTime),
            fromStationName: config.startStation?.name,
            toStationName: config.endStation?.name,
            updatedAt: referenceDate,
            generatedAt: referenceDate,
            coverageStart: baselineCoverage.start,
            coverageEnd: baselineCoverage.end,
            routeSignature: routeSignature
        )
        guard baselineWidgetData.needsTopUp(referenceDate: referenceDate, targetEnd: morningWindow.end) else {
            WidgetSyncDiagnostics.coverageDecision(
                reason: "topup_not_needed_baseline",
                referenceDate: referenceDate,
                coverageEnd: baselineWidgetData.coverageEnd,
                targetEnd: morningWindow.end,
                futureCount: baselineWidgetData.futureConnections(from: referenceDate).count
            )
            return
        }

        WidgetSyncDiagnostics.coverageDecision(
            reason: "topup_scheduled",
            referenceDate: referenceDate,
            coverageEnd: baselineWidgetData.coverageEnd,
            targetEnd: morningWindow.end,
            futureCount: baselineWidgetData.futureConnections(from: referenceDate).count
        )

        lastWidgetCoverageTopUpAttemptAt = referenceDate
        widgetCoverageTopUpTask = Task { [weak self] in
            await self?.performWidgetCoverageTopUp(
                fromStation: start,
                toStation: end,
                sourceConnections: sourceConnections,
                referenceDate: referenceDate,
                targetEnd: morningWindow.end
            )
        }
    }

    private func performWidgetCoverageTopUp(
        fromStation: Station,
        toStation: Station,
        sourceConnections: [TrainConnection],
        referenceDate: Date,
        targetEnd: Date
    ) async {
        defer { widgetCoverageTopUpTask = nil }
        guard !Task.isCancelled else { return }

        var mergedConnections = sourceConnections.filter { $0.departureTime > referenceDate }
        var seenIds = Set(mergedConnections.map(\.id))
        let routeKey = "\(fromStation.id)-\(toStation.id)"
        let cursorSeedDateTime = paginationSeedDateTime ?? referenceDate
        var cursorToken =
            paginationRouteKey == routeKey
                ? forwardPaginationCursor : nil
        var departureCursor =
            (mergedConnections.map(\.departureTime).max() ?? referenceDate)
                .addingTimeInterval(1)
        if departureCursor < referenceDate { departureCursor = referenceDate }

        let targetConnectionFloor = WidgetSnapshotBuilder.targetConnectionFloor(
            referenceDate: referenceDate,
            targetEnd: targetEnd,
            cap: widgetStoredConnectionLimit
        )
        let maxHops = max(4, (widgetStoredConnectionLimit / max(1, widgetTopUpBatchSize)) + 2)
        for _ in 0 ..< maxHops {
            guard !Task.isCancelled else { return }

            let candidates = widgetSnapshotCandidates(from: mergedConnections, at: referenceDate)
            let coverage = WidgetSnapshotBuilder.coverageRange(for: candidates, fallback: referenceDate)
            let hasEnoughCoverage = coverage.end >= targetEnd
                && candidates.count >= targetConnectionFloor
            if hasEnoughCoverage
                || candidates.count >= widgetStoredConnectionLimit
                || (cursorToken == nil && departureCursor > targetEnd)
            {
                WidgetSyncDiagnostics.coverageDecision(
                    reason: "topup_complete",
                    referenceDate: referenceDate,
                    coverageEnd: coverage.end,
                    targetEnd: targetEnd,
                    futureCount: candidates.count
                )
                break
            }

            do {
                let pageConnections: [TrainConnection]
                if let token = cursorToken {
                    let page = try await transportService.fetchConnectionsPage(
                        from: fromStation,
                        to: toStation,
                        transportType: transportType,
                        seedDateTime: cursorSeedDateTime,
                        pageSize: widgetTopUpBatchSize,
                        cursor: token
                    )
                    pageConnections = page.connections
                    if let nextToken = page.forwardCursor, nextToken != token {
                        cursorToken = nextToken
                    } else {
                        cursorToken = nil
                    }
                } else {
                    pageConnections = try await transportService.fetchConnections(
                        from: fromStation,
                        to: toStation,
                        transportType: transportType,
                        departureTime: departureCursor,
                        count: widgetTopUpBatchSize
                    )
                }

                guard !pageConnections.isEmpty else { break }

                var furthestDeparture = departureCursor
                for connection in pageConnections {
                    if connection.departureTime > referenceDate, seenIds.insert(connection.id).inserted {
                        mergedConnections.append(connection)
                    }
                    if connection.departureTime > furthestDeparture {
                        furthestDeparture = connection.departureTime
                    }
                }

                if furthestDeparture > departureCursor {
                    departureCursor = furthestDeparture.addingTimeInterval(1)
                } else if cursorToken == nil {
                    break
                }

                if pageConnections.count < widgetTopUpBatchSize, cursorToken == nil { break }
            } catch {
                WidgetSyncDiagnostics.coverageDecision(
                    reason: "topup_fetch_failed",
                    referenceDate: referenceDate,
                    coverageEnd: nil,
                    targetEnd: targetEnd,
                    futureCount: mergedConnections.count
                )
                return
            }
        }

        if paginationRouteKey == routeKey {
            forwardPaginationCursor = cursorToken
        }
        updateWidgetIfNeeded(with: mergedConnections, scheduleCoverageTopUp: false)
    }

    private func resetWidgetSyncStateForRouteChange() {
        widgetCoverageTopUpTask?.cancel()
        widgetCoverageTopUpTask = nil
        lastWidgetCoverageTopUpAttemptAt = nil
        lastWidgetSnapshotSignature = nil
    }

    private func resetPaginationState() {
        paginationRouteKey = nil
        paginationSeedDateTime = nil
        forwardPaginationCursor = nil
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
               skippedTodayGlobally || route.isOccurrenceSkipped(on: referenceDate, direction: .toWork)
            {
                continue
            }
            try? await notificationService.scheduleCommuteNotification(
                route: route, day: day, schedule: schedule, direction: .toWork, config: cfg
            )
        }

        for (day, schedule) in route.toHomeSchedules where route.isDayActive(day, direction: .toHome) {
            if day == todayWeekday,
               skippedTodayGlobally || route.isOccurrenceSkipped(on: referenceDate, direction: .toHome)
            {
                continue
            }
            try? await notificationService.scheduleCommuteNotification(
                route: route, day: day, schedule: schedule, direction: .toHome, config: cfg
            )
        }
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
                refreshWidgetsFromLoadedConnections()
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

    private func fetchConnectionsPageWithTimeout(
        from start: Station,
        to end: Station,
        seedDateTime: Date,
        pageSize: Int = FetchLimits.connectionBatchSize,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> ConnectionPage {
        let service = transportService
        let type = transportType
        final class CompletionState {
            private let lock = NSLock()
            private var didComplete = false

            func resumeOnce(
                _ result: Result<ConnectionPage, Error>,
                continuation: CheckedContinuation<ConnectionPage, Error>
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
                    let value = try await service.fetchConnectionsPage(
                        from: start,
                        to: end,
                        transportType: type,
                        seedDateTime: seedDateTime,
                        pageSize: pageSize,
                        cursor: nil
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
