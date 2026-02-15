import BackgroundTasks
import Foundation
import WidgetKit

/// Service responsible for refreshing widget data in the background
final class WidgetRefreshService {
    static let shared = WidgetRefreshService()
    static let taskIdentifier = "com.veno.gleis.widgetRefresh"

    private init() {}

    /// Refresh widget data by fetching latest connections - always fetch live data
    func refreshWidgetData() async {
        // Access MainActor-isolated properties on the main actor
        let (config, savedRoute, startStation, endStation) = await MainActor.run {
            let settingsManager = SettingsManager.shared
            let config = settingsManager.trainCommuteConfig
            return (config, settingsManager.savedCommuteRoute, config.startStation, config.endStation)
        }

        guard let startStation, let endStation else { return }

        do {
            // Always fetch fresh, live connection data
            let connections = try await TransportService.shared.fetchConnections(
                from: startStation, to: endStation, transportType: .trainCommute
            )

            // Filter out past connections before processing
            let now = Date()
            let futureConnections = connections.filter { $0.departureTime > now }
            guard !futureConnections.isEmpty else { return }

            // Build widget data with live information
            let widgetConnections = await MainActor.run {
                futureConnections.prefix(3).map { conn -> WidgetConnection in
                    let stopCount = conn.legs.first { !$0.isWalking }?.stopCount
                    let hasReminder =
                        SettingsManager.shared.isReminderSet(for: conn.id) || savedRoute.matchesSchedule(conn) != nil
                    return WidgetConnection(
                        id: conn.id, lineNumber: conn.lineNumber, lineColors: conn.lineColors,
                        departureTime: conn.departureTime,
                        arrivalTime: conn.arrivalTime, destination: conn.arrivalStation.name, platform: conn.platform,
                        transfers: conn.transfers, delay: conn.delay, stopCount: stopCount, hasReminder: hasReminder
                    )
                }
            }

            let leaveTimes = futureConnections.prefix(3).map { conn -> Date in
                let travelTime = config.travelTime(for: startStation.id) ?? 0
                let bufferTime = config.bufferTime(for: startStation.id) ?? 0
                return conn.departureTime.addingTimeInterval(TimeInterval(-(travelTime + bufferTime) * 60))
            }

            let widgetData = WidgetData(
                transportType: .trainCommute, connections: Array(widgetConnections), leaveTimes: leaveTimes,
                updatedAt: Date()
            )

            AppGroupStorage.saveWidgetData(for: .trainCommute, data: widgetData)
            WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
        } catch {
            // Silently fail in background - widget will show cached data
            print("Background widget refresh failed: \(error)")
        }
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
}
