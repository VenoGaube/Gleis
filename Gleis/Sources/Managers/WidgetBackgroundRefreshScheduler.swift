import BackgroundTasks
import Foundation
import OSLog
import WidgetKit

enum WidgetBackgroundRefreshScheduler {
    static let taskIdentifier = "com.veno.gleis.widget.refresh"
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
            _ = await WidgetSnapshotReconciler.reconcile(allowNetworkFallback: true)
            // Repeat-schedule alerts are planned as dated occurrences, so they need
            // topping up even on days the user never opens the app — which is also
            // what makes a skipped date take effect without a launch.
            if Task.isCancelled { return }
            await CommuteNotificationReconciler.reconcile()

            if Task.isCancelled { return }
            await deliverServiceAlerts()
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
            live = try await TransportService.shared.fetchConnections(from: start, to: end)
        } catch is CancellationError {
            return
        } catch {
            logger.error(
                "Background alert fetch failed for \(start.id, privacy: .public) to \(end.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        let liveIds = Set(live.map(\.id))
        let cached = await ConnectionCache.shared.load(from: start, to: end) ?? []
        let connections = live + cached.filter { !liveIds.contains($0.id) }
        guard !connections.isEmpty, !Task.isCancelled else { return }

        await ServiceAlertNotifier.deliverAlerts(for: context.reminders, in: connections)
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
