import Combine
import Foundation
import OSLog
import UIKit
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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.veno.gleis", category: "TransportViewModel"
    )
    private static let widgetRetryTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    @Published var connections: LoadingState<[TrainConnection]> = .idle {
        didSet {
            // Anchor the wait here rather than in the loading view. That view sits inside a
            // switch that re-evaluates on every model change, which kept resetting its own
            // `@State` start time and froze the elapsed count at zero.
            if case .loading = connections {
                if loadingStartedAt == nil { loadingStartedAt = Date() }
            } else {
                loadingStartedAt = nil
            }
        }
    }

    /// When the current no-data wait began, for the loading view's elapsed-time copy.
    @Published private(set) var loadingStartedAt: Date?
    @Published var displayConnections: [DisplayConnection] = [] {
        didSet { schedulePhaseUpdate() }
    }
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
    /// The last refresh failure while a list stayed on screen; an empty list shows its error inline instead.
    @Published private(set) var lastRefreshError: GleisError?
    @Published var isLoadingMore = false
    @Published var availableTrainTypes: [TrainType] = []
    @Published var connectionRecovery: ConnectionRecoveryState?

    @Published private(set) var departureAnchor: Date?
    @Published private(set) var anchoredConnections: LoadingState<[DisplayConnection]> = .idle {
        didSet { schedulePhaseUpdate() }
    }
    @Published private(set) var isLoadingMoreAnchored = false
    @Published private(set) var anchoredReachedEnd = false

    let toastManager = ToastManager()

    private let transportService: TransportServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let settingsManager: SettingsManager
    private let searchService: StationSearchService
    private let connectionCache = ConnectionCache.shared
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var phaseUpdateTimer: Timer?
    private var lastPhaseUpdateAt = Date()
    private var isAutoRefreshRunning = false
    private var inFlightRefresh: InFlightRefresh?
    private var inFlightRefreshIsUserInitiated = false
    private var lastFetchedRouteKey: String?
    private var lastInitializedFilterRouteKey: String?
    private var isLoadingStations = false
    private var lastWidgetSnapshotSignature: String?
    private var widgetCoverageTopUpTask: Task<Void, Never>?
    private var lastWidgetCoverageTopUpAttemptAt: Date?
    private var paginationRouteKey: String?
    private var paginationSeedDateTime: Date?
    private var forwardPaginationCursor: String?
    private var dismissedRecoverySignatures = Set<String>()
    private var anchoredTrainConnections: [TrainConnection] = []
    private var anchoredRouteKey: String?
    private var anchoredSeedDateTime: Date?
    private var anchoredForwardCursor: String?
    private var anchoredJumpTask: Task<Void, Never>?
    /// Bumped by every jump and return to now, so a late page from an older search is dropped.
    private var anchoredRequestGeneration = 0
    private var enteredBackgroundAt: Date?
    private var reminderResyncSignatures = Set<String>()
    private let minimumLiveRefreshInterval: TimeInterval = 45
    private static let nearDepartureRefreshInterval: TimeInterval = 60
    private static let farDepartureRefreshInterval: TimeInterval = 5 * 60
    /// A departure closer than this keeps the foreground refresh at the near interval.
    private static let nearDepartureWindow: TimeInterval = 30 * 60
    /// Request budgets sized against measured provider latency rather than optimism.
    private static let userInitiatedFetchTimeout: TimeInterval = 20
    private static let backgroundFetchTimeout: TimeInterval = 25
    private var consecutiveAutomaticFetchFailures = 0
    private var automaticRefreshBackoffUntil: Date?
    private var serviceAlertStabilizer = ServiceAlertStabilizer()
    private var lastCommuteNotificationReconcileDay: Date?
    private let widgetStoredConnectionLimit = 60
    private let widgetTopUpBatchSize = FetchLimits.connectionBatchSize
    private let widgetTopUpMinimumInterval: TimeInterval = 10 * 60
    /// Wall-clock ceiling for one background coverage top-up run.
    private static let widgetTopUpBudget: TimeInterval = 60
    /// A jumped search starts this far before the chosen time, so trains just before it still show.
    private static let anchoredSearchLeadTime: TimeInterval = 10 * 60
    private static let anchoredInitialConnectionTarget = 12
    /// A jumped time this far in the past is dropped, and the list goes back to now.
    private static let anchorExpiryInterval: TimeInterval = 60 * 60
    /// A background stay longer than this drops a jumped search on return.
    private static let backgroundResetInterval: TimeInterval = 30 * 60

    var config: RouteConfiguration { settingsManager.trainCommuteConfig }

    private struct InFlightRefresh {
        let routeKey: String?
        let task: Task<Void, Never>
    }

    private var configuredRouteKey: String? {
        guard let start = config.startStation, let end = config.endStation, start.id != end.id else { return nil }
        return "\(start.id)-\(end.id)"
    }

    init(
        transportService: TransportServiceProtocol = TransportService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        settingsManager: SettingsManager? = nil
    ) {
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
        observeAppLifecycle()
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.enteredBackgroundAt = Date() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.returnToNowAfterLongBackground() }
            .store(in: &cancellables)
    }

    private func returnToNowAfterLongBackground() {
        let now = Date()
        defer { enteredBackgroundAt = nil }
        if let enteredBackgroundAt, now.timeIntervalSince(enteredBackgroundAt) > Self.backgroundResetInterval {
            returnToNow()
            return
        }
        returnToNowIfAnchorExpired(now: now)
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
                Task { await self.refreshConnections(isUserInitiated: false) }
                if departureAnchor != nil { Task { await self.rerunJump() } }
            }
            .store(in: &cancellables)

        // Watch for timing/filter changes - only updates display (no re-fetch needed).
        // `useDelayInLeaveTime` belongs here too: it shifts every leave time, so
        // leaving it out meant the setting appeared to do nothing until the next fetch.
        settingsManager.$trainCommuteConfig.dropFirst().removeDuplicates { old, new in
            old.stationTravelTimes == new.stationTravelTimes && old.stationBufferTimes == new.stationBufferTimes
                && old.excludedTrainTypes == new.excludedTrainTypes
                && old.walkingTimeMinutes == new.walkingTimeMinutes
                && old.bufferTimeMinutes == new.bufferTimeMinutes
                && old.usesDelayInLeaveTime == new.usesDelayInLeaveTime
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
            stations = try await transportService.fetchStations()
        } catch {
            // Station search works without the browse pool, so a failed load is logged and not shown.
            if !(error is CancellationError) {
                Self.logger.error("Station pool load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func searchStations(_ query: String) async -> [Station] {
        await searchService.searchStations(query)
    }

    /// Runs one refresh per route at a time: a trigger for the same route awaits the one in flight,
    /// and a trigger for another route cancels it and waits for it to unwind before starting.
    func refreshConnections(isUserInitiated: Bool = false) async {
        await reconcileCommuteNotificationsIfNeeded()

        while let inFlight = inFlightRefresh {
            if inFlight.routeKey == configuredRouteKey, !inFlight.task.isCancelled {
                if isUserInitiated { inFlightRefreshIsUserInitiated = true }
                await inFlight.task.value
                return
            }
            inFlight.task.cancel()
            await inFlight.task.value
        }

        inFlightRefreshIsUserInitiated = isUserInitiated
        let task = Task { @MainActor [weak self] in
            await self?.performRefresh()
            self?.inFlightRefresh = nil
        }
        inFlightRefresh = InFlightRefresh(routeKey: configuredRouteKey, task: task)
        await task.value
    }

    /// Reads the in-flight flags at each decision, so a user trigger that joins mid-run still gets user semantics.
    private func performRefresh() async {
        isRefreshingConnections = true
        defer { isRefreshingConnections = false }

        let currentConfig = config
        guard let start = currentConfig.startStation, let end = currentConfig.endStation, start.id != end.id else {
            connections = .idle
            isShowingCachedData = false
            lastRefreshError = nil
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
        var existingConnections: [TrainConnection]? = connections.value
        let isRouteChange = routeKey != lastFetchedRouteKey
        if isRouteChange {
            // A station swap should fetch and render its own route state.
            // Do not keep previous-route items around as fallback state.
            existingConnections = nil
        }
        if isRouteChange {
            serviceAlertStabilizer.reset()
            lastRefreshError = nil
            clearServiceDegradedState()
            resetPaginationState()
            resetWidgetSyncStateForRouteChange()
        }

        if !inFlightRefreshIsUserInitiated,
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
        if !inFlightRefreshIsUserInitiated, !isRouteChange, connections.isLoaded, !isShowingCachedData {
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
        //
        // This deliberately runs on a route change too, including the first load of a
        // session. `lastFetchedRouteKey` starts nil, so cold launch always looked like a
        // route change and skipped the cache entirely — the app sat on a skeleton for the
        // full 5-8s provider round trip with valid cached departures already on disk.
        // Showing another route's data was the real worry, and the cache is keyed by
        // route, so it cannot do that; the stale in-memory state is already cleared above.
        if existingConnections == nil,
           let cached = await connectionCache.load(from: start, to: end)
        {
            let futureCached = cached.filter { $0.departureTime > Date() }
            if !futureCached.isEmpty {
                lastFetchedRouteKey = routeKey
                resetPaginationState()
                setConnections(futureCached)
                evaluateReminderReliability(with: futureCached)
                isShowingCachedData = true
                lastUpdated = await connectionCache.lastUpdateTime(from: start, to: end)
                updateWidgetIfNeeded(with: futureCached)
                existingConnections = futureCached
            }
        }

        // Offline: use cached data
        if !NetworkMonitor.shared.isConnected,
           let cached = await connectionCache.load(from: start, to: end)
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
            lastUpdated = await connectionCache.lastUpdateTime(from: start, to: end)
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
            // The provider's own time-to-first-byte is 3-8s on a transfer route, and the
            // gate-then-shop fallback chain adds an auth round trip on top. An 8s budget
            // raced the server and lost, which is what surfaced as "Update failed,
            // showing previous data" on pull-to-refresh.
            let timeout = inFlightRefreshIsUserInitiated ? Self.userInitiatedFetchTimeout : Self.backgroundFetchTimeout

            // Launch starts this route's first fetch before any view exists. Claiming it
            // here inherits a request that is already seconds along, rather than starting
            // a second one beside it. Its seed becomes the pagination anchor so "load
            // more" continues that same search.
            let requestSeedDateTime: Date
            let page: ConnectionPage
            if let prewarmed = try await claimPrewarmedPageWithTimeout(
                from: start, to: end, timeoutSeconds: timeout
            ) {
                page = prewarmed.page
                requestSeedDateTime = prewarmed.seedDateTime
            } else {
                requestSeedDateTime = Date()
                page = try await fetchConnectionsPageWithTimeout(
                    from: start,
                    to: end,
                    seedDateTime: requestSeedDateTime,
                    pageSize: fetchCount,
                    timeoutSeconds: timeout
                )
            }
            let result = page.connections
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }

            let now = Date()
            let futureResult = result.filter { $0.departureTime > now }

            let merged: [TrainConnection]
            // Read the list as it is now, so trains a load-more appended during this fetch survive the merge.
            if let existing = connections.value ?? existingConnections, !isRouteChange, !inFlightRefreshIsUserInitiated {
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
            lastRefreshError = nil
            updateWidgetIfNeeded(with: merged)
            consecutiveAutomaticFetchFailures = 0
            automaticRefreshBackoffUntil = nil
            clearServiceDegradedState()
            // Written after the list is shown so the disk write does not delay the first paint.
            await connectionCache.save(result, from: start, to: end)
        } catch {
            // A superseded fetch was cancelled on purpose: no error state, and the backoff stays as it was.
            if Task.isCancelled { return }
            guard config.startStation?.id == start.id, config.endStation?.id == end.id else { return }
            scheduleAutomaticRefreshBackoffIfNeeded(for: error, isUserInitiated: inFlightRefreshIsUserInitiated)
            let mappedError = GleisError.from(error)
            if let existing = existingConnections, !existing.isEmpty {
                if !(error is CancellationError) { lastRefreshError = mappedError }
                isShowingCachedData = true
                updateWidgetIfNeeded(with: existing)
                return
            }
            if let cached = await connectionCache.load(from: start, to: end) {
                let futureConnections = cached.filter { $0.departureTime > Date() }
                guard !futureConnections.isEmpty else {
                    connections = .error(mappedError)
                    return
                }
                lastFetchedRouteKey = routeKey
                resetPaginationState()
                setConnections(futureConnections)
                evaluateReminderReliability(with: futureConnections)
                isShowingCachedData = true
                lastRefreshError = mappedError
                lastUpdated = await connectionCache.lastUpdateTime(from: start, to: end)
                updateWidgetIfNeeded(with: futureConnections)
            } else {
                connections = .error(mappedError)
                connectionRecovery = nil
            }
        }
    }

    func scheduleNotification(for connection: TrainConnection, replacingReminderId: String? = nil) async {
        do {
            let fromStationId = config.startStation?.id

            // Schedule each alert independently. For an imminent departure the
            // five-minute warning may already be in the past while the leave-time
            // alert is still useful, so one lapsed alert must not void the other.
            let scheduledFiveMinute = try await scheduleAlertIfStillAhead(
                for: connection, type: .fiveMinuteWarning, fromStationId: fromStationId
            )
            let scheduledExactTime = try await scheduleAlertIfStillAhead(
                for: connection, type: .exactTime, fromStationId: fromStationId
            )

            guard scheduledFiveMinute || scheduledExactTime else {
                throw GleisError.reminderTimeAlreadyPassed
            }

            let lineNumber = connection.lineNumber.uppercased()
            toastManager.show(
                scheduledFiveMinute
                    ? "Reminder set for \(lineNumber)"
                    : "Reminder set for \(lineNumber) at leave time only",
                type: .success
            )
            selectedConnection = connection

            let createdAt =
                replacingReminderId.flatMap { id in
                    settingsManager.scheduledReminders.first(where: { $0.id == id })?.createdAt
                } ?? Date()
            let reminder = ScheduledReminder(
                id: connection.id, lineNumber: connection.lineNumber,
                destination: connection.arrivalStation.name, platform: connection.platform,
                departureTime: config.effectiveDepartureTime(for: connection),
                leaveTime: calculateLeaveTime(for: connection), delayMinutes: connection.delay,
                fiveMinuteWarning: scheduledFiveMinute,
                exactTimeWarning: scheduledExactTime, createdAt: createdAt
            )
            if let replacingReminderId, replacingReminderId != connection.id {
                notificationService.cancelNotification(id: "\(replacingReminderId)_fiveMinuteWarning")
                notificationService.cancelNotification(id: "\(replacingReminderId)_exactTime")
                await notificationService.cancelServiceAlertNotifications(reminderId: replacingReminderId)
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
                        handleError(GleisError.notificationPermissionDenied)
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

    /// Schedules one alert, reporting whether it was actually registered.
    /// A trigger time that has already passed is expected, not an error.
    private func scheduleAlertIfStillAhead(
        for connection: TrainConnection,
        type: NotificationType,
        fromStationId: String?
    ) async throws -> Bool {
        do {
            try await notificationService.scheduleNotification(
                for: connection, config: config, type: type, fromStationId: fromStationId
            )
            return true
        } catch GleisError.reminderTimeAlreadyPassed {
            return false
        }
    }

    func cancelNotification(for connection: TrainConnection) {
        notificationService.cancelNotification(id: "\(connection.id)_fiveMinuteWarning")
        notificationService.cancelNotification(id: "\(connection.id)_exactTime")
        Task { await notificationService.cancelServiceAlertNotifications(reminderId: connection.id) }
        if selectedConnection?.id == connection.id { selectedConnection = nil }
        settingsManager.removeReminder(connectionId: connection.id)

        if let direction = settingsManager.savedCommuteRoute.matchesSchedule(connection) {
            var route = settingsManager.savedCommuteRoute
            route.skipOccurrence(on: connection.departureTime, direction: direction)
            route.pruneOldSkippedDates()
            settingsManager.updateSavedCommuteRoute(route)
            // Replan rather than cancelling by identifier: occurrences are dated, so
            // the skipped one has to drop out and the following one take its place.
            Task { [notificationService] in
                await CommuteNotificationReconciler.reconcile(notificationService: notificationService)
            }
            toastManager.show("Skipped this connection", type: .info)
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
        toastManager.show("Unpinned My Journey", type: .info)
        rebuildDisplayConnections()
        refreshWidgetsFromLoadedConnections()
    }

    func addRecentStation(_ station: Station) {
        settingsManager.addRecentStation(station)
    }

    /// Runs beside any refresh, and drops its batch if a refresh replaced the train it paged on from.
    func loadMoreConnections() async {
        guard case let .loaded(current) = connections, let last = current.last else { return }
        guard !isLoadingMore else { return }
        guard let start = config.startStation, let end = config.endStation,
              lastFetchedRouteKey == "\(start.id)-\(end.id)"
        else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let pageSize = FetchLimits.connectionBatchSize
        let maxPaginationHops = FetchLimits.maxCoveragePages
        // What a single "load more" should add. The provider caps a response at six or
        // seven trips whatever we ask for, so one hop is a few minutes of timetable on
        // a dense route — far less than a scroll-to-bottom implies.
        let targetAppendCount = 15

        do {
            let now = Date()
            let routeKey = "\(start.id)-\(end.id)"
            var seenIds = Set(current.map(\.id))
            var appendedConnections: [TrainConnection] = []
            var nextCursor: String? =
                paginationRouteKey == routeKey
                    ? forwardPaginationCursor : nil
            let seedAtStart = paginationSeedDateTime
            let seedDateTime = seedAtStart ?? Date()
            var canUseCursorPagination = nextCursor != nil

            if canUseCursorPagination {
                for _ in 0 ..< maxPaginationHops {
                    guard let cursorToken = nextCursor else { break }
                    let page = try await transportService.fetchConnectionsPage(
                        from: start,
                        to: end,
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
                    // Keep paging on appended count alone. Testing `more.count < pageSize`
                    // ended every loop after one hop, because a full gate response is
                    // always smaller than the page size we asked for.
                    if appendedConnections.count >= targetAppendCount { break }
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

                    if appendedConnections.count >= targetAppendCount { break }
                }
            }

            // A refresh that landed meanwhile started a new search, and its cursor wins.
            if paginationRouteKey == routeKey, paginationSeedDateTime == seedAtStart {
                forwardPaginationCursor = nextCursor
            }
            // A user refresh replaces the list, so a batch paged from the old tail would leave a gap.
            guard connections.value?.contains(where: { $0.id == last.id }) == true else { return }
            appendConnectionsToLoadedList(appendedConnections, routeKey: routeKey, referenceDate: Date())
        } catch { if !(error is CancellationError) { toastManager.show("Can't load more connections. Try again.", type: .error) } }
    }

    // MARK: - Jumped Departure Time

    /// The first live train there is still time to leave for, for the banner above a jumped list.
    var nextLiveConnection: DisplayConnection? {
        let now = Date()
        return displayConnections
            .filter { $0.leaveTime > now }
            .min { $0.connection.departureTime < $1.connection.departureTime }
    }

    /// Searches from `anchor` into a list of its own; the live list, widget and reminder checks stay on now.
    func jump(to anchor: Date) async {
        guard let start = config.startStation, let end = config.endStation, start.id != end.id else {
            returnToNow()
            return
        }
        clearAnchoredResults(showing: .loading)
        departureAnchor = anchor
        anchoredRouteKey = "\(start.id)-\(end.id)"
        let generation = anchoredRequestGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.fetchAnchoredConnections(from: start, to: end, anchor: anchor, generation: generation)
        }
        anchoredJumpTask = task
        await task.value
    }

    func returnToNow() {
        departureAnchor = nil
        clearAnchoredResults(showing: .idle)
    }

    /// Repeats the jump at the same time, or refreshes the live list if the anchor has expired.
    func rerunJump() async {
        returnToNowIfAnchorExpired(now: Date())
        guard let anchor = departureAnchor else {
            await refreshConnections(isUserInitiated: true)
            return
        }
        await jump(to: anchor)
    }

    func loadMoreAnchored() async {
        await loadMoreAnchored(untilShownCount: filteredByTrainType(anchoredTrainConnections).count + 1)
    }

    private func loadMoreAnchored(untilShownCount shownTarget: Int) async {
        guard departureAnchor != nil, anchoredConnections.isLoaded, !isLoadingMoreAnchored, !anchoredReachedEnd,
              !isAnchoredListAtCap, let start = config.startStation, let end = config.endStation,
              let seedDateTime = anchoredSeedDateTime
        else { return }
        let generation = anchoredRequestGeneration
        guard isCurrentAnchoredRequest(generation) else { return }
        isLoadingMoreAnchored = true
        defer { if generation == anchoredRequestGeneration { isLoadingMoreAnchored = false } }

        do {
            guard let run = try await fetchNextAnchoredPages(
                from: start, to: end, seedDateTime: seedDateTime, generation: generation, untilShownCount: shownTarget
            ) else { return }
            anchoredForwardCursor = run.forwardCursor
            if run.forwardCursor == nil { anchoredReachedEnd = true }
            appendAnchoredPage(run.additions, generation: generation)
        } catch {
            guard isCurrentAnchoredRequest(generation), !(error is CancellationError) else { return }
            toastManager.show("Can't load more connections. Try again.", type: .error)
        }
    }

    private struct AnchoredPageRun {
        let additions: [TrainConnection]
        let forwardCursor: String?
    }

    /// Pages forward until the filtered list holds `shownTarget` trains or the provider runs out; nil when a newer jump superseded it.
    /// Each page gets its own timeout, and a page that fails after earlier ones landed ends the run with what it has.
    private func fetchNextAnchoredPages(
        from start: Station,
        to end: Station,
        seedDateTime: Date,
        generation: Int,
        untilShownCount shownTarget: Int
    ) async throws -> AnchoredPageRun? {
        let startCursor = anchoredForwardCursor
        var cursor = startCursor
        var seenIds = Set(anchoredTrainConnections.map(\.id))
        var additions: [TrainConnection] = []
        let target = min(shownTarget, config.displayMaxConnections)
        for _ in 0 ..< FetchLimits.maxCoveragePages {
            let page: ConnectionPage
            do {
                page = try await fetchConnectionsPageWithTimeout(
                    from: start, to: end, seedDateTime: seedDateTime, cursor: cursor,
                    timeoutSeconds: Self.userInitiatedFetchTimeout
                )
            } catch let error where !(error is CancellationError) && cursor != startCursor {
                guard isCurrentAnchoredRequest(generation) else { return nil }
                Self.logger.error(
                    "Anchored page after seed \(seedDateTime.formatted(.iso8601), privacy: .public) failed, keeping earlier pages: \(error.localizedDescription, privacy: .public)"
                )
                break
            }
            guard isCurrentAnchoredRequest(generation) else { return nil }
            additions += page.connections.filter { seenIds.insert($0.id).inserted }
            guard let nextCursor = page.forwardCursor, nextCursor != cursor else {
                return AnchoredPageRun(additions: additions, forwardCursor: nil)
            }
            cursor = nextCursor
            let preview = mergedAnchoredConnections(anchoredTrainConnections, adding: additions, now: Date())
            if filteredByTrainType(preview).count >= target { break }
        }
        return AnchoredPageRun(additions: additions, forwardCursor: cursor)
    }

    private func fetchAnchoredConnections(from start: Station, to end: Station, anchor: Date, generation: Int) async {
        let seedDateTime = anchor.addingTimeInterval(-Self.anchoredSearchLeadTime)
        let service = transportService
        let coverage = ConnectionCoverage(minimumCount: Self.anchoredInitialConnectionTarget, notBefore: seedDateTime)
        do {
            // The coverage run stops starting pages once its budget is spent, so allow one more page on top.
            let result = try await withTimeout(seconds: coverage.budget + Self.userInitiatedFetchTimeout) { [weak self] in
                try await service.fetchConnectionsCovering(
                    from: start,
                    to: end,
                    seedDateTime: seedDateTime,
                    coverage: coverage,
                    onPage: { [weak self] page in
                        await self?.appendAnchoredPage(page, generation: generation)
                    }
                )
            }
            guard isCurrentAnchoredRequest(generation) else { return }
            anchoredSeedDateTime = result.seedDateTime
            anchoredForwardCursor = result.forwardCursor
            if result.forwardCursor == nil { anchoredReachedEnd = true }
            appendAnchoredPage(result.connections, generation: generation)
            // The coverage target counts trains the filter may hide, so page on until enough of them show.
            if filteredByTrainType(anchoredTrainConnections).count < Self.anchoredInitialConnectionTarget {
                await loadMoreAnchored(untilShownCount: Self.anchoredInitialConnectionTarget)
            }
        } catch {
            guard isCurrentAnchoredRequest(generation), !(error is CancellationError) else { return }
            Self.logger.error(
                "Jumped search from \(seedDateTime.formatted(.iso8601), privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            guard let lastShownConnection = anchoredTrainConnections.last else {
                anchoredConnections = .error(GleisError.from(error))
                return
            }
            // Keep the pages that arrived; load-more then starts a fresh search after the last one.
            anchoredSeedDateTime = lastShownConnection.departureTime.addingTimeInterval(1)
            anchoredForwardCursor = nil
        }
    }

    private func appendAnchoredPage(_ page: [TrainConnection], generation: Int) {
        guard isCurrentAnchoredRequest(generation) else { return }
        let now = Date()
        anchoredTrainConnections = mergedAnchoredConnections(anchoredTrainConnections, adding: page, now: now)
        anchoredConnections = .loaded(makeAnchoredDisplayConnections(at: now))
    }

    /// Adds new future trains by id and collapses true duplicates; it keeps every loaded train so a filter change leaves no gap before the cursor.
    private func mergedAnchoredConnections(
        _ existing: [TrainConnection],
        adding page: [TrainConnection],
        now: Date
    ) -> [TrainConnection] {
        let knownIds = Set(existing.map(\.id))
        let additions = page.filter { $0.departureTime > now && !knownIds.contains($0.id) }
        return ConnectionDeduplicator.deduplicate(
            existing + additions,
            context: deduplicationContext(previous: existing)
        )
    }

    /// The row cap is checked under the current filter, so a filter change can lift it and let paging go on.
    private var isAnchoredListAtCap: Bool {
        filteredByTrainType(anchoredTrainConnections).count >= config.displayMaxConnections
    }

    /// Caps the shown rows, since the stored list can hold more trains than the cap shows.
    private func makeAnchoredDisplayConnections(at currentTime: Date) -> [DisplayConnection] {
        Array(makeDisplayConnections(from: anchoredTrainConnections, at: currentTime).prefix(config.displayMaxConnections))
    }

    private func rebuildAnchoredDisplayConnections() {
        guard anchoredConnections.isLoaded else { return }
        anchoredConnections = .loaded(makeAnchoredDisplayConnections(at: Date()))
    }

    private func isCurrentAnchoredRequest(_ generation: Int) -> Bool {
        generation == anchoredRequestGeneration && anchoredRouteKey == configuredRouteKey
    }

    private func clearAnchoredResults(showing state: LoadingState<[DisplayConnection]>) {
        anchoredJumpTask?.cancel()
        anchoredJumpTask = nil
        anchoredRequestGeneration += 1
        anchoredTrainConnections = []
        anchoredRouteKey = nil
        anchoredSeedDateTime = nil
        anchoredForwardCursor = nil
        isLoadingMoreAnchored = false
        anchoredReachedEnd = false
        anchoredConnections = state
    }

    private func returnToNowIfAnchorExpired(now: Date) {
        guard let anchor = departureAnchor, now.timeIntervalSince(anchor) > Self.anchorExpiryInterval else { return }
        returnToNow()
    }

    func startAutoRefresh() {
        isAutoRefreshRunning = true
        scheduleNextAutoRefresh()
        updateDisplayConnectionPhases()
    }

    func stopAutoRefresh() {
        isAutoRefreshRunning = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        phaseUpdateTimer?.invalidate()
        phaseUpdateTimer = nil
    }

    func cancelCurrentFetch() {
        inFlightRefresh?.task.cancel()
    }

    private func scheduleNextAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: nextAutoRefreshInterval(), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.runAutoRefresh() }
        }
    }

    private func runAutoRefresh() async {
        settingsManager.checkAndClearExpiredPin()
        returnToNowIfAnchorExpired(now: Date())
        await refreshConnections()
        guard isAutoRefreshRunning else { return }
        scheduleNextAutoRefresh()
    }

    private func nextAutoRefreshInterval() -> TimeInterval {
        let now = Date()
        let nextDeparture = displayConnections.map(\.connection.departureTime).filter { $0 > now }.min()
        guard let nextDeparture else { return Self.farDepartureRefreshInterval }
        return nextDeparture.timeIntervalSince(now) > Self.nearDepartureWindow
            ? Self.farDepartureRefreshInterval
            : Self.nearDepartureRefreshInterval
    }

    func setImmediateRouteTransitionState(start: Station?, end: Station?) {
        let hasValidRoute = start != nil && end != nil && start?.id != end?.id
        connections = hasValidRoute ? .loading : .idle
        displayConnections = []
        availableTrainTypes = []
        resetPaginationState()
        isShowingCachedData = false
        lastRefreshError = nil
        connectionRecovery = nil
        if departureAnchor != nil {
            // The config observer re-runs the jump for the new route once the change settles.
            if hasValidRoute { clearAnchoredResults(showing: .loading) } else { returnToNow() }
        }
        if !hasValidRoute {
            clearServiceDegradedState()
            resetWidgetSyncStateForRouteChange()
            updateWidget(with: [])
        }
    }

    deinit {
        refreshTimer?.invalidate()
        phaseUpdateTimer?.invalidate()
        inFlightRefresh?.task.cancel()
        widgetCoverageTopUpTask?.cancel()
        anchoredJumpTask?.cancel()
    }

    // MARK: - Display Connection Management

    /// Arms a one-shot timer for the soonest phase boundary across the rows; cards draw the countdown themselves.
    private func schedulePhaseUpdate() {
        phaseUpdateTimer?.invalidate()
        phaseUpdateTimer = nil
        guard isAutoRefreshRunning else { return }
        let now = Date()
        let rows = displayConnections + (anchoredConnections.value ?? [])
        guard let nextBoundary = rows.compactMap({ $0.nextPhaseBoundary(after: now) }).min() else { return }
        let timer = Timer(fire: nextBoundary, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDisplayConnectionPhases() }
        }
        RunLoop.main.add(timer, forMode: .common)
        phaseUpdateTimer = timer
    }

    private func updateDisplayConnectionPhases() {
        let now = Date()
        var updated = displayConnections
        var didChangePhase = false
        for i in updated.indices {
            updated[i].playThresholdHaptic(from: lastPhaseUpdateAt, to: now)
            if updated[i].updatePhase(at: now) { didChangePhase = true }
        }
        lastPhaseUpdateAt = now

        // Haptics come from the live list alone, so a train shown in both lists buzzes once.
        var didChangeAnchoredPhase = false
        if case var .loaded(anchoredRows) = anchoredConnections {
            for i in anchoredRows.indices {
                if anchoredRows[i].updatePhase(at: now) { didChangeAnchoredPhase = true }
            }
            if didChangeAnchoredPhase { anchoredConnections = .loaded(anchoredRows) }
        }

        if didChangePhase {
            displayConnections = updated
        } else if !didChangeAnchoredPhase {
            schedulePhaseUpdate()
        }
    }

    private func rebuildDisplayConnections() {
        rebuildAnchoredDisplayConnections()
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

        if let start = config.startStation, let end = config.endStation {
            pruneFiltersForRouteIfNeeded(for: "\(start.id)-\(end.id)", available: availableTrainTypes)
        }

        let currentTime = Date()
        lastPhaseUpdateAt = currentTime
        displayConnections = makeDisplayConnections(from: connections, at: currentTime)
    }

    /// Applies the train-type filter and reminder and pin state shared by the live and jumped lists.
    private func makeDisplayConnections(from connections: [TrainConnection], at currentTime: Date) -> [DisplayConnection] {
        let filtered = filteredByTrainType(connections)
        let route = settingsManager.savedCommuteRoute
        return filtered.map { connection in
            let isSelected =
                settingsManager.isReminderSet(for: connection.id)
                || route.hasActiveReminder(for: connection)
            return DisplayConnection(
                connection: connection, leaveTime: calculateLeaveTime(for: connection), isSelected: isSelected,
                isPinned: settingsManager.isPinned(connection.id), currentTime: currentTime
            )
        }
    }

    private func filteredByTrainType(_ connections: [TrainConnection]) -> [TrainConnection] {
        let excluded = config.excludedTrainTypes
        #if DEBUG
        let hidden = connections.filter { excluded.contains($0.trainType) }
        if !hidden.isEmpty {
            Self.logger.info(
                "Trip list: train-type filter hides \(hidden.map(ConnectionIdentity.debugDescription).joined(separator: " | "), privacy: .public)"
            )
        }
        #endif
        return excluded.isEmpty ? connections : connections.filter { !excluded.contains($0.trainType) }
    }

    private func setConnections(_ newConnections: [TrainConnection]) {
        let previousConnections = connections.value ?? []
        let stabilized = serviceAlertStabilizer.stabilize(newConnections, previous: previousConnections)
        let resolved = ConnectionDeduplicator.deduplicate(
            stabilized,
            context: deduplicationContext(previous: previousConnections)
        )
        #if DEBUG
        let resolvedIds = Set(resolved.map(\.id))
        let merged = stabilized.filter { !resolvedIds.contains($0.id) }
        Self.logger.info(
            "Trip list: \(stabilized.count) in, \(resolved.count) kept, merged as duplicates: \(merged.map(ConnectionIdentity.debugDescription).joined(separator: " | "), privacy: .public)"
        )
        #endif
        connections = .loaded(resolved)
        settingsManager.syncPinnedJourney(with: resolved)
        rebuildDisplayConnections()
    }

    private func deduplicationContext(previous: [TrainConnection]) -> ConnectionDeduplicator.PreferenceContext {
        settingsManager.checkAndClearExpiredPin()
        return ConnectionDeduplicator.PreferenceContext(
            pinnedConnectionId: settingsManager.pinnedJourney?.connectionId,
            reminderIds: Set(settingsManager.scheduledReminders.map(\.id)),
            savedRoute: settingsManager.savedCommuteRoute,
            previousIds: Set(previous.map(\.id))
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
            message = "No connections."
        } else if isServiceDegraded, isShowingCachedData {
            state = .fallback
            message = widgetServiceDegradedMessage(referenceDate: now)
        } else {
            state = .fresh
            message = nil
        }
        let action: WidgetRecoveryAction = isRouteConfigured ? .openLiveRoute : .openSetup

        let widgetData = WidgetData(
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
        AppGroupStorage.savePrimaryWidgetData(widgetData)
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
        if let stored = AppGroupStorage.loadPrimaryWidgetData(),
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
        // Hop count alone stopped bounding this once the page size dropped to what the
        // provider actually returns: the same 60-connection target now needs ten hops
        // instead of six, and a hop has measured anywhere from 3s to 15s. Bound the run
        // in wall-clock time too, and keep whatever arrived.
        let deadline = Date().addingTimeInterval(Self.widgetTopUpBudget)
        for _ in 0 ..< maxHops {
            guard !Task.isCancelled else { return }
            if Date() >= deadline { break }

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

        // The pages this top-up just paid for are exactly what the list is short of:
        // a gate response caps at six or seven trips, so the first fetch alone leaves
        // the list showing minutes of timetable on a dense route. Publish them.
        appendConnectionsToLoadedList(mergedConnections, routeKey: routeKey, referenceDate: referenceDate)
    }

    /// Merges fetched pages into the rendered live list, keeping what is already shown.
    private func appendConnectionsToLoadedList(
        _ fetchedConnections: [TrainConnection],
        routeKey: String,
        referenceDate: Date
    ) {
        guard let start = config.startStation, let end = config.endStation,
              "\(start.id)-\(end.id)" == routeKey, lastFetchedRouteKey == routeKey,
              case let .loaded(current) = connections
        else { return }

        let currentIds = Set(current.map(\.id))
        let additions = fetchedConnections.filter {
            !currentIds.contains($0.id) && $0.departureTime > referenceDate
        }
        guard !additions.isEmpty else { return }
        setConnections((current + additions).sorted { $0.departureTime < $1.departureTime })
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
        // Expired reminders used to linger until the user happened to open Settings,
        // growing the stored list and eating into the system's pending-notification budget.
        settingsManager.pruneExpiredReminders(before: now)
        let relevantReminders = settingsManager.scheduledReminders
            .filter { reminder in
                reminder.departureTime > now.addingTimeInterval(-15 * 60)
            }
            .sorted { $0.departureTime < $1.departureTime }

        notifyServiceAlertsForReminders(relevantReminders, liveConnections: liveConnections)

        guard !relevantReminders.isEmpty else {
            connectionRecovery = nil
            return
        }

        let liveConnectionsById = Dictionary(liveConnections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lastLoadedDeparture = liveConnections.map(config.effectiveDepartureTime(for:)).max()

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
            // Past the end of the loaded list a train is unloaded, not missing.
            guard let lastLoadedDeparture, reminder.departureTime <= lastLoadedDeparture else { continue }
            let replacement = bestReplacementConnection(for: reminder, in: liveConnections, now: now)
            // A reminder saved under an older id still matches its train by line and scheduled minute.
            if let replacement, isSameScheduledTrain(replacement, as: reminder) { continue }
            let signature = recoverySignature(reminder: reminder, suggestedConnectionId: replacement?.id)
            if dismissedRecoverySignatures.contains(signature) { continue }

            connectionRecovery = ConnectionRecoveryState(
                id: signature,
                kind: .missingSelection,
                title: "Your train isn't running",
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
        await CommuteNotificationReconciler.reconcile(notificationService: notificationService)
        lastCommuteNotificationReconcileDay = today
    }

    private func notifyServiceAlertsForReminders(
        _ reminders: [ScheduledReminder],
        liveConnections: [TrainConnection]
    ) {
        guard !reminders.isEmpty else { return }
        Task { [notificationService] in
            await ServiceAlertNotifier.deliverAlerts(
                for: reminders,
                in: liveConnections,
                notificationService: notificationService
            )
        }
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

        let normalizedReminderPlatform = ConnectionIdentity.normalizePlatform(reminder.platform)
        let normalizedLivePlatform = ConnectionIdentity.normalizePlatform(liveConnection.platform)
        // Only treat a platform change as notable once the live feed actually names
        // a platform; losing a previously known one is a data gap, not a change.
        let platformChanged = !normalizedLivePlatform.isEmpty && normalizedReminderPlatform != normalizedLivePlatform

        // A delay that shrinks is good news and should not raise a disruption prompt.
        let delayWorsened = liveConnection.delay > reminder.delayMinutes

        // The reminder stores the *effective* (delay-adjusted) departure, so compare
        // against the same projection rather than the raw scheduled time.
        let liveEffectiveDeparture = config.effectiveDepartureTime(for: liveConnection)
        let departureShifted = abs(liveEffectiveDeparture.timeIntervalSince(reminder.departureTime)) >= 60

        return platformChanged || delayWorsened || departureShifted
    }

    private func bestReplacementConnection(
        for reminder: ScheduledReminder,
        in connections: [TrainConnection],
        now: Date
    ) -> TrainConnection? {
        // A cancelled service is not a replacement for a cancelled service.
        let futureConnections = connections.filter { $0.departureTime > now && !$0.isCancelled }
        guard !futureConnections.isEmpty else { return nil }

        let normalizedReminderLine = ConnectionIdentity.normalizeLine(reminder.lineNumber)
        let sameLine = futureConnections.filter { ConnectionIdentity.normalizeLine($0.lineNumber) == normalizedReminderLine }
        if let closestSameLine = sameLine.min(by: {
            abs($0.departureTime.timeIntervalSince(reminder.departureTime))
                < abs($1.departureTime.timeIntervalSince(reminder.departureTime))
        }) {
            return closestSameLine
        }

        return futureConnections.min { $0.departureTime < $1.departureTime }
    }

    /// Both stored and live departures carry the delay, so each side takes its own delay out before the minutes are compared.
    private func isSameScheduledTrain(_ connection: TrainConnection, as reminder: ScheduledReminder) -> Bool {
        guard ConnectionIdentity.normalizeLine(connection.lineNumber) == ConnectionIdentity.normalizeLine(reminder.lineNumber)
        else { return false }
        let connectionScheduled = connection.departureTime.addingTimeInterval(-TimeInterval(connection.delay * 60))
        let reminderScheduled = reminder.departureTime.addingTimeInterval(-TimeInterval(reminder.delayMinutes * 60))
        return ConnectionIdentity.minuteTimestamp(connectionScheduled) == ConnectionIdentity.minuteTimestamp(reminderScheduled)
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
        return "\(reminder.lineNumber) at \(originalTime) is no longer running. Pick another train from the list."
    }

    private func recoveryMessageForUpdate(
        reminder: ScheduledReminder,
        liveConnection: TrainConnection
    ) -> String {
        var parts: [String] = []
        if liveConnection.delay > reminder.delayMinutes {
            parts.append("+\(liveConnection.delay) min")
        }
        if ConnectionIdentity.normalizePlatform(reminder.platform) != ConnectionIdentity.normalizePlatform(liveConnection.platform),
           let platform = liveConnection.platform, !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            parts.append("platform \(platform)")
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let liveEffectiveDeparture = config.effectiveDepartureTime(for: liveConnection)
        if abs(liveEffectiveDeparture.timeIntervalSince(reminder.departureTime)) >= 60 {
            parts.append("departs at \(formatter.string(from: liveEffectiveDeparture))")
        }

        if parts.isEmpty {
            return "ÖBB changed \(reminder.lineNumber). Set your reminder again."
        }
        return "\(reminder.lineNumber) now " + parts.joined(separator: ", ") + "."
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
                let scheduledFiveMinute = try await scheduleAlertIfStillAhead(
                    for: liveConnection, type: .fiveMinuteWarning, fromStationId: fromStationId
                )
                let scheduledExactTime = try await scheduleAlertIfStillAhead(
                    for: liveConnection, type: .exactTime, fromStationId: fromStationId
                )
                guard scheduledFiveMinute || scheduledExactTime else {
                    throw GleisError.reminderTimeAlreadyPassed
                }

                let updatedReminder = ScheduledReminder(
                    id: liveConnection.id,
                    lineNumber: liveConnection.lineNumber,
                    destination: liveConnection.arrivalStation.name,
                    platform: liveConnection.platform,
                    departureTime: config.effectiveDepartureTime(for: liveConnection),
                    leaveTime: calculateLeaveTime(for: liveConnection),
                    delayMinutes: liveConnection.delay,
                    fiveMinuteWarning: scheduledFiveMinute,
                    exactTimeWarning: scheduledExactTime,
                    createdAt: reminder.createdAt
                )

                if reminder.id != updatedReminder.id {
                    notificationService.cancelNotification(id: "\(reminder.id)_fiveMinuteWarning")
                    notificationService.cancelNotification(id: "\(reminder.id)_exactTime")
                    await notificationService.cancelServiceAlertNotifications(reminderId: reminder.id)
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
                    await notificationService.cancelServiceAlertNotifications(reminderId: liveConnection.id)
                }
                reminderResyncSignatures.remove(signature)
            }
        }
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

    /// Shows the alert for a failed user action; refresh failures go to `connections` or `lastRefreshError` instead.
    private func handleError(_ error: Error) {
        let mapped = GleisError.from(error)
        errorTitle = mapped.userFacingTitle
        errorMessage = mapped.userFacingMessage
        showError = true
    }

    /// Awaits a launch-prewarmed page under the same budget as a normal fetch.
    /// Returns nil when there is nothing to claim, so the caller fetches normally.
    private func claimPrewarmedPageWithTimeout(
        from start: Station,
        to end: Station,
        timeoutSeconds: TimeInterval
    ) async throws -> PrewarmedConnectionsPage? {
        let service = transportService
        return try? await withTimeout(seconds: timeoutSeconds) {
            try await service.claimPrewarmedConnections(from: start, to: end)
        }
    }

    /// Runs an operation under a wall-clock budget, cancelling it if the budget expires.
    ///
    /// Structured rather than a raced pair of unstructured `Task`s over a continuation.
    /// That earlier shape had two faults: the timeout task slept out its full duration
    /// even after the work finished, leaving a task alive per fetch; and a
    /// `CancellationError` from the operation resumed nothing, so a cancelled fetch
    /// stalled the caller for the entire budget instead of returning at once.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1.0, seconds) * 1_000_000_000))
                throw GleisError.timeout("Request timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw GleisError.timeout("Request timed out")
            }
            return first
        }
    }

    private func fetchConnectionsPageWithTimeout(
        from start: Station,
        to end: Station,
        seedDateTime: Date,
        pageSize: Int = FetchLimits.connectionBatchSize,
        cursor: String? = nil,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> ConnectionPage {
        let service = transportService
        return try await withTimeout(seconds: timeoutSeconds) {
            try await service.fetchConnectionsPage(
                from: start,
                to: end,
                seedDateTime: seedDateTime,
                pageSize: pageSize,
                cursor: cursor
            )
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

    /// Drops filters that no longer apply to the new route.
    ///
    /// This used to clear the whole exclusion set on any route change, so a filter
    /// silently vanished when you swapped stations — even swapping back. Exclusions
    /// for types the new route still runs are kept; only now-irrelevant ones go.
    private func pruneFiltersForRouteIfNeeded(for routeKey: String, available: [TrainType]) {
        guard lastInitializedFilterRouteKey != routeKey else { return }
        guard !available.isEmpty else { return }
        lastInitializedFilterRouteKey = routeKey

        let availableIds = Set(available.map(\.id))
        let retained = config.excludedTrainTypes.filter { availableIds.contains($0.id) }
        guard retained != config.excludedTrainTypes else { return }

        var updated = config
        updated.excludedTrainTypes = retained
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
            return "Not up to date. Showing saved departures."
        }
        if retryAt <= referenceDate {
            return "Not up to date. Trying again now."
        }
        return "Not up to date. Trying again around \(Self.widgetRetryTimeFormatter.string(from: retryAt))."
    }
}
