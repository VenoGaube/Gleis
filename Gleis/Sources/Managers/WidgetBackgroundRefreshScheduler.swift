import BackgroundTasks
import Foundation
import OSLog
import WidgetKit

enum WidgetBackgroundRefreshScheduler {
    static let taskIdentifier = "com.veno.gleis.widget.refresh"
    // Short so the cached departures still get used well inside the background task's time.
    private static let serviceAlertFetchTimeLimit: TimeInterval = 8
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.veno.gleis", category: "BackgroundRefresh")

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let earliestBeginDate = nextMorningRefreshDate(from: Date())
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
            WidgetSyncDiagnostics.backgroundTaskScheduled(
                identifier: taskIdentifier,
                earliestBeginDate: earliestBeginDate
            )
        } catch {
            // Best-effort scheduling; ignore failures silently in production.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        WidgetSyncDiagnostics.backgroundTaskRunStarted(identifier: taskIdentifier)
        let work = Task {
            if Task.isCancelled { return }
            // Alerts go first so a slow widget reconcile cannot use up the task's time before they are sent.
            await deliverServiceAlerts()
            if Task.isCancelled { return }
            _ = await WidgetSnapshotReconciler.reconcile(allowNetworkFallback: true)
            // Repeat-schedule alerts are planned as dated occurrences, so they need
            // topping up even on days the user never opens the app — which is also
            // what makes a skipped date take effect without a launch.
            if Task.isCancelled { return }
            await CommuteNotificationReconciler.reconcile()
            if !Task.isCancelled {
                WidgetSyncDiagnostics.backgroundTaskRunCompleted(identifier: taskIdentifier, success: true)
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = {
            work.cancel()
            WidgetSyncDiagnostics.backgroundTaskRunCompleted(identifier: taskIdentifier, success: false)
            task.setTaskCompleted(success: false)
        }
    }

    /// Raises disruption alerts for reminded journeys without needing the app open.
    /// Fetches live departures so alerts do not depend on how old the app's cache is.
    private static func deliverServiceAlerts() async {
        struct Context {
            let reminders: [ScheduledReminder]
            let start: Station?
            let end: Station?
        }

        let context = await MainActor.run { () -> Context in
            let settings = SettingsManager.shared
            settings.pruneExpiredReminders()
            let config = settings.trainCommuteConfig
            return Context(
                reminders: settings.scheduledReminders,
                start: config.startStation,
                end: config.endStation
            )
        }

        guard !context.reminders.isEmpty, let start = context.start, let end = context.end else { return }
        var live: [TrainConnection] = []
        do {
            live = try await fetchLiveConnections(from: start, to: end)
        } catch is CancellationError {
            return
        } catch {
            logger.error(
                "Background alert fetch failed for \(start.id, privacy: .public) to \(end.id, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
        let liveIds = Set(live.map(\.id))
        let cached = await ConnectionCache.shared.load(from: start, to: end) ?? []
        let connections = live + cached.filter { !liveIds.contains($0.id) }
        guard !connections.isEmpty, !Task.isCancelled else { return }

        await ServiceAlertNotifier.deliverAlerts(for: context.reminders, in: connections)
    }

    /// Fetches live departures, throwing `GleisError.timeout` once `serviceAlertFetchTimeLimit` passes.
    private static func fetchLiveConnections(from start: Station, to end: Station) async throws -> [TrainConnection] {
        try await withThrowingTaskGroup(of: [TrainConnection].self) { group in
            group.addTask { try await TransportService.shared.fetchConnections(from: start, to: end) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(serviceAlertFetchTimeLimit * 1_000_000_000))
                throw GleisError.timeout("Background alert fetch timed out after \(serviceAlertFetchTimeLimit) s")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw GleisError.timeout("Background alert fetch returned no result")
            }
            return first
        }
    }

    private static func nextMorningRefreshDate(from now: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let targetHour = 5
        let targetMinute = 30
        let todayRefresh = calendar.date(byAdding: .minute, value: targetHour * 60 + targetMinute, to: dayStart)
            ?? now.addingTimeInterval(60 * 60)
        if now < todayRefresh {
            return todayRefresh
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return calendar.date(byAdding: .minute, value: targetHour * 60 + targetMinute, to: tomorrow)
            ?? now.addingTimeInterval(12 * 60 * 60)
    }
}
