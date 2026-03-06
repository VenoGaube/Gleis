import Foundation
import os

enum WidgetSyncDiagnostics {
    #if DEBUG
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.veno.gleis",
        category: "WidgetSync"
    )
    private static let throttle = WidgetSyncDiagnosticsThrottle()
    private static let throttleInterval: TimeInterval = 8
    #endif

    static func snapshotWriteSkipped(reason: String, routeSignature: String, snapshotSignature: String?) {
        #if DEBUG
        emit(
            key: "snapshot_skip_\(reason)_\(routeSignature)",
            message: "snapshot_skipped reason=\(reason) route=\(routeSignature) signature=\(snapshotSignature ?? "-")"
        )
        #endif
    }

    static func snapshotWriteApplied(
        reason: String,
        routeSignature: String,
        snapshotSignature: String,
        connectionCount: Int,
        coverageStart: Date,
        coverageEnd: Date,
        state: String
    ) {
        #if DEBUG
        emit(
            key: "snapshot_apply_\(reason)_\(routeSignature)",
            message:
            "snapshot_applied reason=\(reason) route=\(routeSignature) signature=\(snapshotSignature) state=\(state) connections=\(connectionCount) coverage=\(iso8601(coverageStart))...\(iso8601(coverageEnd))"
        )
        #endif
    }

    static func timelineReloadTriggered(reason: String) {
        #if DEBUG
        emit(key: "reload_\(reason)", message: "reload_timelines reason=\(reason)")
        #endif
    }

    static func coverageDecision(
        reason: String,
        referenceDate: Date,
        coverageEnd: Date?,
        targetEnd: Date,
        futureCount: Int
    ) {
        #if DEBUG
        let endText = coverageEnd.map(iso8601) ?? "-"
        emit(
            key: "coverage_\(reason)",
            message:
            "coverage_decision reason=\(reason) now=\(iso8601(referenceDate)) coverage_end=\(endText) target_end=\(iso8601(targetEnd)) future_count=\(futureCount)"
        )
        #endif
    }

    static func staleDisplay(reason: String, generatedAt: Date, coverageEnd: Date) {
        #if DEBUG
        emit(
            key: "stale_display_\(reason)",
            message:
            "stale_display reason=\(reason) generated_at=\(iso8601(generatedAt)) coverage_end=\(iso8601(coverageEnd))"
        )
        #endif
    }

    static func backgroundTaskScheduled(identifier: String, earliestBeginDate: Date) {
        #if DEBUG
        emit(
            key: "bg_schedule_\(identifier)",
            message: "bg_task_scheduled id=\(identifier) earliest=\(iso8601(earliestBeginDate))"
        )
        #endif
    }

    static func backgroundTaskRunStarted(identifier: String) {
        #if DEBUG
        emit(key: "bg_start_\(identifier)", message: "bg_task_started id=\(identifier)")
        #endif
    }

    static func backgroundTaskRunCompleted(identifier: String, success: Bool) {
        #if DEBUG
        emit(key: "bg_complete_\(identifier)", message: "bg_task_completed id=\(identifier) success=\(success)")
        #endif
    }

    #if DEBUG
    private static func emit(key: String, message: String) {
        Task {
            let shouldLog = await throttle.shouldLog(key: key, minimumInterval: throttleInterval)
            guard shouldLog else { return }
            logger.debug("\(message, privacy: .public)")
        }
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
    #endif
}

#if DEBUG
private actor WidgetSyncDiagnosticsThrottle {
    private var lastLogByKey: [String: Date] = [:]

    func shouldLog(key: String, minimumInterval: TimeInterval) -> Bool {
        let now = Date()
        if let last = lastLogByKey[key], now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastLogByKey[key] = now
        return true
    }
}
#endif
