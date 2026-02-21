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

        let contexts = buildRefreshContexts(from: snapshot)
        guard !contexts.isEmpty else { return }

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

        if let start = snapshot.liveStartStation, let end = snapshot.liveEndStation {
            contexts.append(contentsOf: contextsForRoutePair(
                routeScope: .liveRoute,
                forwardFrom: start,
                forwardTo: end,
                dayScopes: dayScopes
            ))
        }

        if let home = snapshot.savedRoute.homeStation, let work = snapshot.savedRoute.workStation {
            contexts.append(contentsOf: contextsForRoutePair(
                routeScope: .repeatJourney,
                forwardFrom: home,
                forwardTo: work,
                dayScopes: dayScopes
            ))
        }

        return contexts.filter { $0.fromStation.id != $0.toStation.id }
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

        do {
            let connections = try await TransportService.shared.fetchConnectionsWithoutDetails(
                from: context.fromStation,
                to: context.toStation,
                transportType: .trainCommute,
                departureTime: departure,
                count: FetchLimits.widgetRefreshConnectionCount
            )

            let dayFilteredConnections = filterConnections(connections, for: context.dayScope, now: now)
            let selectedConnections = prioritizeConnections(
                dayFilteredConnections,
                pinnedConnectionId: snapshot.pinnedConnectionId
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
                    || snapshot.savedRoute.matchesSchedule(connection) != nil
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
            AppGroupStorage.markWidgetDataAsFallback(
                for: context.storageKey,
                message: fallbackMessage(for: context),
                updatedAt: now
            )
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
        pinnedConnectionId: String?
    ) -> [TrainConnection] {
        let sorted = connections.sorted { lhs, rhs in
            let lhsPinned = lhs.id == pinnedConnectionId
            let rhsPinned = rhs.id == pinnedConnectionId
            if lhsPinned != rhsPinned { return lhsPinned }
            return lhs.departureTime < rhs.departureTime
        }
        return Array(sorted.prefix(3))
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
