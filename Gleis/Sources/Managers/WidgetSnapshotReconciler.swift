import Foundation
import WidgetKit

enum WidgetSnapshotReconciler {
    private static let fetchPageSize = FetchLimits.connectionBatchSize

    private struct Context {
        let config: RouteConfiguration
        let savedRoute: SavedCommuteRoute
        let reminderIds: Set<String>
        let pinnedConnectionId: String?
    }

    static func reconcile(referenceDate: Date = Date(), allowNetworkFallback: Bool) async -> Bool {
        let now = referenceDate
        let context = await MainActor.run { snapshotContext() }
        let existing = AppGroupStorage.loadPrimaryWidgetData()

        guard
            let start = context.config.startStation,
            let end = context.config.endStation,
            start.id != end.id
        else {
            return persistSetupStateIfNeeded(existing: existing, referenceDate: now)
        }

        let routeSignature = WidgetSnapshotBuilder.routeSignature(startStationId: start.id, endStationId: end.id)
        let targetWindow = WidgetSnapshotBuilder.morningCoverageWindow(from: now)
        if let existing,
           existing.routeSignature == routeSignature,
           !existing.needsTopUp(referenceDate: now, targetEnd: targetWindow.end)
        {
            WidgetSyncDiagnostics.snapshotWriteSkipped(
                reason: "reconcile_coverage_sufficient",
                routeSignature: routeSignature,
                snapshotSignature: existing.snapshotSignature
            )
            return false
        }

        let cachedConnections = await ConnectionCache.shared.load(from: start, to: end) ?? []
        let cacheUpdatedAt = await ConnectionCache.shared.lastUpdateTime(from: start, to: end)
        var mergedConnections = cachedConnections
        var candidates = makeCandidates(from: mergedConnections, context: context, referenceDate: now)
        var coverage = WidgetSnapshotBuilder.coverageRange(for: candidates, fallback: now)
        let targetFloor = WidgetSnapshotBuilder.targetConnectionFloor(
            referenceDate: now,
            targetEnd: targetWindow.end,
            cap: WidgetSnapshotBuilder.maxStoredConnectionLimit
        )
        let cacheSufficient = coverage.end >= targetWindow.end && candidates.count >= targetFloor
        WidgetSyncDiagnostics.coverageDecision(
            reason: cacheSufficient ? "reconcile_cache_sufficient" : "reconcile_cache_insufficient",
            referenceDate: now,
            coverageEnd: coverage.end,
            targetEnd: targetWindow.end,
            futureCount: candidates.count
        )

        var didFetchFromNetwork = false
        var didNetworkFetchFail = false
        if allowNetworkFallback, !cacheSufficient {
            let fetchStart = max(
                now,
                (mergedConnections.map(\.departureTime).max() ?? now).addingTimeInterval(1)
            )
            let fetched = await fetchConnectionsCoveringHorizon(
                from: start,
                to: end,
                startDate: fetchStart,
                targetEnd: targetWindow.end,
                targetCount: WidgetSnapshotBuilder.maxStoredConnectionLimit
            )
            // A cancelled fetch also comes back nil, and is not an outage to report.
            if Task.isCancelled { return false }
            didNetworkFetchFail = fetched == nil
            if let fetched, !fetched.isEmpty {
                didFetchFromNetwork = true
                let deduped = WidgetSnapshotBuilder.deduplicatedByConnectionID(mergedConnections + fetched)
                mergedConnections = deduped.sorted { lhs, rhs in
                    if lhs.departureTime != rhs.departureTime {
                        return lhs.departureTime < rhs.departureTime
                    }
                    return lhs.id < rhs.id
                }
                candidates = makeCandidates(from: mergedConnections, context: context, referenceDate: now)
                coverage = WidgetSnapshotBuilder.coverageRange(for: candidates, fallback: now)
                WidgetSyncDiagnostics.coverageDecision(
                    reason: "reconcile_post_network_topup",
                    referenceDate: now,
                    coverageEnd: coverage.end,
                    targetEnd: targetWindow.end,
                    futureCount: candidates.count
                )
            }
        }

        // Same rule as TransportViewModel.updateWidget: cached departures after a failed fetch are fallback.
        let state: WidgetDataState = didNetworkFetchFail && !candidates.isEmpty ? .fallback : .fresh
        let snapshotSignature = WidgetSnapshotBuilder.snapshotSignature(
            routeSignature: routeSignature,
            stateSignature: state.rawValue,
            candidates: candidates,
            coverageRange: coverage
        )
        if existing?.snapshotSignature == snapshotSignature {
            WidgetSyncDiagnostics.snapshotWriteSkipped(
                reason: "reconcile_signature_unchanged",
                routeSignature: routeSignature,
                snapshotSignature: snapshotSignature
            )
            return false
        }

        let widgetData = WidgetData(
            connections: candidates.map(WidgetSnapshotBuilder.makeWidgetConnection),
            leaveTimes: candidates.map(\.leaveTime),
            fromStationName: start.name,
            toStationName: end.name,
            updatedAt: didFetchFromNetwork ? now : (cacheUpdatedAt ?? now),
            generatedAt: now,
            coverageStart: coverage.start,
            coverageEnd: coverage.end,
            routeSignature: routeSignature,
            snapshotSignature: snapshotSignature,
            state: state,
            stateMessage: candidates.isEmpty
                ? "No connections."
                : (state == .fallback ? "Not up to date. Showing saved departures." : nil),
            recoveryAction: .openLiveRoute
        )
        AppGroupStorage.savePrimaryWidgetData(widgetData)
        WidgetSyncDiagnostics.snapshotWriteApplied(
            reason: "foreground_reconcile",
            routeSignature: routeSignature,
            snapshotSignature: snapshotSignature,
            connectionCount: candidates.count,
            coverageStart: coverage.start,
            coverageEnd: coverage.end,
            state: widgetData.state.rawValue
        )
        WidgetSyncDiagnostics.timelineReloadTriggered(reason: "foreground_reconcile_write")
        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
        return true
    }

    @MainActor
    private static func snapshotContext() -> Context {
        let settings = SettingsManager.shared
        settings.checkAndClearExpiredPin()
        return Context(
            config: settings.trainCommuteConfig,
            savedRoute: settings.savedCommuteRoute,
            reminderIds: Set(settings.scheduledReminders.map(\.id)),
            pinnedConnectionId: settings.pinnedJourney?.connectionId
        )
    }

    private static func makeCandidates(
        from connections: [TrainConnection],
        context: Context,
        referenceDate: Date
    ) -> [WidgetSnapshotCandidate] {
        WidgetSnapshotBuilder.selectCandidates(
            from: connections,
            config: context.config,
            savedRoute: context.savedRoute,
            reminderIds: context.reminderIds,
            pinnedConnectionId: context.pinnedConnectionId,
            referenceDate: referenceDate,
            limit: WidgetSnapshotBuilder.maxStoredConnectionLimit
        )
    }

    private static func persistSetupStateIfNeeded(existing: WidgetData?, referenceDate: Date) -> Bool {
        let routeSignature = WidgetSnapshotBuilder.routeSignature(startStationId: nil, endStationId: nil)
        let coverage = (start: referenceDate, end: referenceDate)
        let setupSignature = WidgetSnapshotBuilder.snapshotSignature(
            routeSignature: routeSignature,
            stateSignature: "fresh",
            candidates: [],
            coverageRange: coverage
        )
        if existing?.snapshotSignature == setupSignature {
            WidgetSyncDiagnostics.snapshotWriteSkipped(
                reason: "setup_signature_unchanged",
                routeSignature: routeSignature,
                snapshotSignature: setupSignature
            )
            return false
        }

        let setupData = WidgetData(
            connections: [],
            leaveTimes: [],
            updatedAt: referenceDate,
            generatedAt: referenceDate,
            coverageStart: coverage.start,
            coverageEnd: coverage.end,
            routeSignature: routeSignature,
            snapshotSignature: setupSignature,
            state: .fresh,
            stateMessage: "Set up your route to see departures.",
            recoveryAction: .openSetup
        )
        AppGroupStorage.savePrimaryWidgetData(setupData)
        WidgetSyncDiagnostics.snapshotWriteApplied(
            reason: "setup_state",
            routeSignature: routeSignature,
            snapshotSignature: setupSignature,
            connectionCount: 0,
            coverageStart: coverage.start,
            coverageEnd: coverage.end,
            state: setupData.state.rawValue
        )
        WidgetSyncDiagnostics.timelineReloadTriggered(reason: "setup_state_write")
        WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
        return true
    }

    private static func fetchConnectionsCoveringHorizon(
        from start: Station,
        to end: Station,
        startDate: Date,
        targetEnd: Date,
        targetCount: Int
    ) async -> [TrainConnection]? {
        var allConnections: [TrainConnection] = []
        var seenIds = Set<String>()
        var cursorToken: String?
        var useCursorPagination = true
        var departureCursor = startDate
        let maxHops = max(4, (targetCount / max(1, fetchPageSize)) + 2)

        for _ in 0 ..< maxHops {
            if !useCursorPagination, departureCursor > targetEnd { break }
            do {
                let pageConnections: [TrainConnection]
                if useCursorPagination {
                    let page = try await TransportService.shared.fetchConnectionsPage(
                        from: start,
                        to: end,
                        seedDateTime: startDate,
                        pageSize: fetchPageSize,
                        cursor: cursorToken
                    )
                    pageConnections = page.connections
                    if let nextCursor = page.forwardCursor, nextCursor != cursorToken {
                        cursorToken = nextCursor
                    } else {
                        useCursorPagination = false
                    }
                } else {
                    pageConnections = try await TransportService.shared.fetchConnections(
                        from: start,
                        to: end,
                        departureTime: departureCursor,
                        count: fetchPageSize
                    )
                }

                guard !pageConnections.isEmpty else { break }

                var furthestDeparture = departureCursor
                for connection in pageConnections {
                    if seenIds.insert(connection.id).inserted {
                        allConnections.append(connection)
                    }
                    if connection.departureTime > furthestDeparture {
                        furthestDeparture = connection.departureTime
                    }
                }

                if furthestDeparture > departureCursor {
                    departureCursor = furthestDeparture.addingTimeInterval(1)
                } else if !useCursorPagination {
                    break
                }

                if allConnections.count >= targetCount { break }
                if !useCursorPagination, pageConnections.count < fetchPageSize { break }
            } catch {
                WidgetSyncDiagnostics.coverageDecision(
                    reason: "reconcile_network_fetch_failed",
                    referenceDate: startDate,
                    coverageEnd: nil,
                    targetEnd: targetEnd,
                    futureCount: allConnections.count
                )
                return nil
            }
        }

        return allConnections.sorted { lhs, rhs in
            if lhs.departureTime != rhs.departureTime { return lhs.departureTime < rhs.departureTime }
            return lhs.id < rhs.id
        }
    }
}
