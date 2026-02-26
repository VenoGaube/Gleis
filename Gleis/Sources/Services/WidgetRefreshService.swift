import BackgroundTasks
import Foundation
import WidgetKit

/// Service responsible for refreshing widget data in the background
final class WidgetRefreshService {
    static let shared = WidgetRefreshService()
    static let taskIdentifier = "com.veno.gleis.widgetRefresh"
    private let stateLock = NSLock()
    private var isRefreshing = false
    private var lastRefreshAt: Date?
    private let minimumRefreshInterval: TimeInterval = 45

    private init() {}

    private struct WidgetRefreshSnapshot {
        let config: RouteConfiguration
        let savedRoute: SavedCommuteRoute
        let liveStartStation: Station?
        let liveEndStation: Station?
        let reminderIds: Set<String>
        let pinnedConnectionId: String?
    }

    private struct WidgetRefreshContext: Hashable {
        let storageKey: WidgetDataStorageKey
        let fromStation: Station
        let toStation: Station
        let dayScope: WidgetDayScope
    }

    /// Refresh widget data for all supported widget intent combinations.
    func refreshWidgetData(force: Bool = false) async {
        guard beginRefresh(force: force) else { return }
        defer { endRefresh() }

        let snapshot = await MainActor.run {
            let settingsManager = SettingsManager.shared
            settingsManager.checkAndClearExpiredPin()
            let config = settingsManager.trainCommuteConfig
            return WidgetRefreshSnapshot(
                config: config,
                savedRoute: settingsManager.savedCommuteRoute,
                liveStartStation: config.startStation,
                liveEndStation: config.endStation,
                reminderIds: Set(settingsManager.scheduledReminders.map(\.id)),
                pinnedConnectionId: settingsManager.pinnedJourney?.connectionId
            )
        }

        let now = Date()
        persistUnavailableRouteStates(from: snapshot, updatedAt: now)

        let contexts = buildRefreshContexts(from: snapshot)
        guard !contexts.isEmpty else {
            WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for context in contexts {
                group.addTask { [context] in
                    await self.refreshContext(context, snapshot: snapshot)
                }
            }
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
    }

    /// Schedule the next background refresh - always schedule for fresh data
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)

        // iOS limits background refreshes, but we want data as fresh as possible
        // Schedule for 15 minutes (minimum allowed by iOS)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do { try BGTaskScheduler.shared.submit(request) } catch {
            print("Failed to schedule background refresh: \(error)")
        }
    }

    private func buildRefreshContexts(from snapshot: WidgetRefreshSnapshot) -> [WidgetRefreshContext] {
        var contexts: [WidgetRefreshContext] = []
        let dayScopes: [WidgetDayScope] = [.today, .tomorrow]

        let routePairs: [(scope: WidgetRouteScope, from: Station?, to: Station?)] = [
            (.liveRoute, snapshot.liveStartStation, snapshot.liveEndStation),
            (.repeatJourney, snapshot.savedRoute.homeStation, snapshot.savedRoute.workStation),
        ]

        for route in routePairs {
            guard isValidRoutePair(route.from, route.to),
                  let fromStation = route.from,
                  let toStation = route.to
            else { continue }
            contexts.append(contentsOf: contextsForRoutePair(
                routeScope: route.scope,
                forwardFrom: fromStation,
                forwardTo: toStation,
                dayScopes: dayScopes
            ))
        }

        return contexts.filter { $0.fromStation.id != $0.toStation.id && !$0.storageKey.isDefaultKey }
    }

    private func contextsForRoutePair(
        routeScope: WidgetRouteScope,
        forwardFrom: Station,
        forwardTo: Station,
        dayScopes: [WidgetDayScope]
    ) -> [WidgetRefreshContext] {
        var result: [WidgetRefreshContext] = []
        for dayScope in dayScopes {
            result.append(
                WidgetRefreshContext(
                    storageKey: WidgetDataStorageKey(
                        transportType: .trainCommute,
                        routeScope: routeScope,
                        directionScope: .forward,
                        dayScope: dayScope
                    ),
                    fromStation: forwardFrom,
                    toStation: forwardTo,
                    dayScope: dayScope
                )
            )

            result.append(
                WidgetRefreshContext(
                    storageKey: WidgetDataStorageKey(
                        transportType: .trainCommute,
                        routeScope: routeScope,
                        directionScope: .reverse,
                        dayScope: dayScope
                    ),
                    fromStation: forwardTo,
                    toStation: forwardFrom,
                    dayScope: dayScope
                )
            )
        }
        return result
    }

    private func refreshContext(_ context: WidgetRefreshContext, snapshot: WidgetRefreshSnapshot) async {
        let now = Date()
        let departure = departureQueryDate(for: context.dayScope, now: now)
        let coverageEnd = coverageEndDate(for: context.dayScope, now: now)

        do {
            let connections = try await fetchConnectionsCoveringHorizon(
                for: context,
                departure: departure,
                coverageEnd: coverageEnd
            )

            let dayFilteredConnections = filterConnections(connections, for: context.dayScope, now: now)
            let selectedConnections = prioritizeConnections(
                dayFilteredConnections,
                pinnedConnectionId: snapshot.pinnedConnectionId,
                reminderIds: snapshot.reminderIds,
                savedRoute: snapshot.savedRoute
            )

            if selectedConnections.isEmpty {
                let staleData = WidgetData(
                    transportType: .trainCommute,
                    connections: [],
                    leaveTimes: [],
                    fromStationName: context.fromStation.name,
                    toStationName: context.toStation.name,
                    updatedAt: now,
                    state: .stale,
                    stateMessage: staleMessage(for: context),
                    recoveryAction: recoveryAction(for: context.storageKey.routeScope)
                )
                AppGroupStorage.saveWidgetData(for: context.storageKey, data: staleData)
                return
            }

            let widgetConnections = selectedConnections.map { connection in
                let stopCount = connection.legs.first { !$0.isWalking }?.stopCount
                let hasReminder =
                    snapshot.reminderIds.contains(connection.id)
                    || snapshot.savedRoute.hasActiveReminder(for: connection)
                let isPinned = snapshot.pinnedConnectionId == connection.id

                return WidgetConnection(
                    id: connection.id,
                    lineNumber: connection.lineNumber,
                    lineColors: connection.lineColors,
                    departureTime: connection.departureTime,
                    arrivalTime: connection.arrivalTime,
                    destination: connection.arrivalStation.name,
                    platform: connection.platform,
                    transfers: connection.transfers,
                    delay: connection.delay,
                    stopCount: stopCount,
                    hasReminder: hasReminder,
                    isPinned: isPinned,
                    hasServiceAlert: (connection.serviceAlerts ?? []).contains(where: \.isActive)
                )
            }

            let travelTime = snapshot.config.travelTime(for: context.fromStation.id) ?? 0
            let bufferTime = snapshot.config.bufferTime(for: context.fromStation.id) ?? 0
            let leaveTimes = selectedConnections.map { connection in
                connection.departureTime.addingTimeInterval(TimeInterval(-(travelTime + bufferTime) * 60))
            }

            let widgetData = WidgetData(
                transportType: .trainCommute,
                connections: widgetConnections,
                leaveTimes: leaveTimes,
                fromStationName: context.fromStation.name,
                toStationName: context.toStation.name,
                updatedAt: now,
                state: .fresh,
                recoveryAction: recoveryAction(for: context.storageKey.routeScope)
            )

            AppGroupStorage.saveWidgetData(for: context.storageKey, data: widgetData)
        } catch {
            saveFallbackData(for: context, updatedAt: now)
        }
    }

    private func beginRefresh(force: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isRefreshing { return false }
        if !force,
           let last = lastRefreshAt,
           Date().timeIntervalSince(last) < minimumRefreshInterval
        {
            return false
        }
        isRefreshing = true
        lastRefreshAt = Date()
        return true
    }

    private func endRefresh() {
        stateLock.lock()
        isRefreshing = false
        stateLock.unlock()
    }

    private func departureQueryDate(for dayScope: WidgetDayScope, now: Date) -> Date {
        switch dayScope {
        case .today:
            return now
        case .tomorrow:
            return startOfTomorrow(from: now)
        }
    }

    private func startOfTomorrow(from now: Date) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.startOfDay(for: tomorrow)
    }

    private func coverageEndDate(for dayScope: WidgetDayScope, now: Date) -> Date {
        let horizonSeconds = TimeInterval(FetchLimits.widgetCoverageHorizonHours * 60 * 60)
        let calendar = Calendar.current

        switch dayScope {
        case .today:
            guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return now.addingTimeInterval(horizonSeconds)
            }
            return min(endOfDay, now.addingTimeInterval(horizonSeconds))
        case .tomorrow:
            let start = startOfTomorrow(from: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                return start.addingTimeInterval(horizonSeconds)
            }
            return min(end, start.addingTimeInterval(horizonSeconds))
        }
    }

    private func fetchConnectionsCoveringHorizon(
        for context: WidgetRefreshContext,
        departure: Date,
        coverageEnd: Date
    ) async throws -> [TrainConnection] {
        let pageSize = FetchLimits.widgetRefreshConnectionCount
        let maxHops = 4
        var allConnections: [TrainConnection] = []
        var seenIds = Set<String>()
        var cursor = departure

        for _ in 0 ..< maxHops {
            let page = try await TransportService.shared.fetchConnections(
                from: context.fromStation,
                to: context.toStation,
                transportType: .trainCommute,
                departureTime: cursor,
                count: pageSize
            )
            guard !page.isEmpty else { break }

            for connection in page where !seenIds.contains(connection.id) {
                seenIds.insert(connection.id)
                allConnections.append(connection)
            }

            guard let furthestDeparture = page.map(\.departureTime).max() else { break }
            if furthestDeparture >= coverageEnd { break }
            if furthestDeparture <= cursor { break }

            cursor = furthestDeparture.addingTimeInterval(1)
            if page.count < pageSize { break }
        }

        return allConnections.sorted { lhs, rhs in
            if lhs.departureTime != rhs.departureTime {
                return lhs.departureTime < rhs.departureTime
            }
            return lhs.id < rhs.id
        }
    }

    private func filterConnections(
        _ connections: [TrainConnection],
        for dayScope: WidgetDayScope,
        now: Date
    ) -> [TrainConnection] {
        let calendar = Calendar.current
        switch dayScope {
        case .today:
            return connections.filter { $0.departureTime > now }
        case .tomorrow:
            let start = startOfTomorrow(from: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
            return connections.filter { $0.departureTime >= start && $0.departureTime < end }
        }
    }

    private func prioritizeConnections(
        _ connections: [TrainConnection],
        pinnedConnectionId: String?,
        reminderIds: Set<String>,
        savedRoute: SavedCommuteRoute
    ) -> [TrainConnection] {
        let selectedConnectionIds = Set(connections.compactMap { connection in
            if reminderIds.contains(connection.id) || savedRoute.hasActiveReminder(for: connection) {
                return connection.id
            }
            return nil
        })

        let sorted = connections.sorted { lhs, rhs in
            let lhsPinned = lhs.id == pinnedConnectionId
            let rhsPinned = rhs.id == pinnedConnectionId
            if lhsPinned != rhsPinned { return lhsPinned }

            let lhsSelected = selectedConnectionIds.contains(lhs.id)
            let rhsSelected = selectedConnectionIds.contains(rhs.id)
            if lhsSelected != rhsSelected { return lhsSelected }

            if lhs.departureTime != rhs.departureTime {
                return lhs.departureTime < rhs.departureTime
            }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(FetchLimits.widgetStoredConnectionLimit))
    }

    private func persistUnavailableRouteStates(from snapshot: WidgetRefreshSnapshot, updatedAt: Date) {
        let routePairs: [(scope: WidgetRouteScope, from: Station?, to: Station?)] = [
            (.liveRoute, snapshot.liveStartStation, snapshot.liveEndStation),
            (.repeatJourney, snapshot.savedRoute.homeStation, snapshot.savedRoute.workStation),
        ]

        for route in routePairs where !isValidRoutePair(route.from, route.to) {
            saveUnavailableRouteState(
                routeScope: route.scope,
                forwardFrom: route.from,
                forwardTo: route.to,
                message: unavailableRouteMessage(routeScope: route.scope, from: route.from, to: route.to),
                updatedAt: updatedAt
            )
        }
    }

    private func saveUnavailableRouteState(
        routeScope: WidgetRouteScope,
        forwardFrom: Station?,
        forwardTo: Station?,
        message: String,
        updatedAt: Date
    ) {
        let dayScopes: [WidgetDayScope] = [.today, .tomorrow]
        let directions: [WidgetDirectionScope] = [.forward, .reverse]
        let recoveryAction = recoveryAction(for: routeScope)

        for dayScope in dayScopes {
            for direction in directions {
                let fromName = direction == .forward ? forwardFrom?.name : forwardTo?.name
                let toName = direction == .forward ? forwardTo?.name : forwardFrom?.name
                let key = WidgetDataStorageKey(
                    transportType: .trainCommute,
                    routeScope: routeScope,
                    directionScope: direction,
                    dayScope: dayScope
                )
                // The primary/default widget snapshot is sourced from TransportViewModel.
                // Background refresh should not overwrite it.
                if key.isDefaultKey { continue }
                let data = WidgetData(
                    transportType: .trainCommute,
                    connections: [],
                    leaveTimes: [],
                    fromStationName: fromName,
                    toStationName: toName,
                    updatedAt: updatedAt,
                    state: .stale,
                    stateMessage: message,
                    recoveryAction: recoveryAction
                )
                AppGroupStorage.saveWidgetData(for: key, data: data)
            }
        }
    }

    private func unavailableRouteMessage(routeScope: WidgetRouteScope, from: Station?, to: Station?) -> String {
        if let from, let to, from.id == to.id {
            return "Choose different stations to show departures."
        }

        switch routeScope {
        case .liveRoute:
            return "Set your current route to show live departures."
        case .repeatJourney:
            return "Set your morning and afternoon route to show departures."
        }
    }

    private func saveFallbackData(for context: WidgetRefreshContext, updatedAt: Date) {
        let existing = AppGroupStorage.loadWidgetData(for: context.storageKey)
        let shouldReuseExistingConnections = existing.map {
            normalizedStationToken($0.fromStationName) == normalizedStationToken(context.fromStation.name)
                && normalizedStationToken($0.toStationName) == normalizedStationToken(context.toStation.name)
        } ?? false

        let fallbackData = WidgetData(
            transportType: .trainCommute,
            connections: shouldReuseExistingConnections ? (existing?.connections ?? []) : [],
            leaveTimes: shouldReuseExistingConnections ? (existing?.leaveTimes ?? []) : [],
            fromStationName: context.fromStation.name,
            toStationName: context.toStation.name,
            updatedAt: updatedAt,
            state: .fallback,
            stateMessage: fallbackMessage(for: context),
            recoveryAction: recoveryAction(for: context.storageKey.routeScope)
        )
        AppGroupStorage.saveWidgetData(for: context.storageKey, data: fallbackData)
    }

    private func normalizedStationToken(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isValidRoutePair(_ from: Station?, _ to: Station?) -> Bool {
        guard let from, let to else { return false }
        return from.id != to.id
    }

    private func recoveryAction(for routeScope: WidgetRouteScope) -> WidgetRecoveryAction {
        switch routeScope {
        case .liveRoute:
            return .openLiveRoute
        case .repeatJourney:
            return .openRepeatJourney
        }
    }

    private func staleMessage(for context: WidgetRefreshContext) -> String {
        switch context.dayScope {
        case .today:
            return "No more departures today."
        case .tomorrow:
            return "No departures found for tomorrow."
        }
    }

    private func fallbackMessage(for context: WidgetRefreshContext) -> String {
        switch context.dayScope {
        case .today:
            return "Showing last known departures."
        case .tomorrow:
            return "Showing last known departures for tomorrow."
        }
    }
}
