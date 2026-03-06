import SwiftUI
import UserNotifications
import BackgroundTasks
import WidgetKit

// MARK: - OrientationManager

class OrientationManager: ObservableObject {
    static let shared = OrientationManager()
    @Published var allowLandscape = false
}

// MARK: - GleisApp

@main
struct GleisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var deepLinkConnectionId: String?
    @StateObject private var launchBootstrapper = AppLaunchBootstrapper()

    init() {
        // Configure status bar and navigation bar appearance for proper safe area handling
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if launchBootstrapper.isReady {
                    ContentView(selectedTab: $selectedTab, deepLinkConnectionId: $deepLinkConnectionId)
                } else {
                    AppLaunchLoadingView(statusText: launchBootstrapper.statusText)
                }
            }
            .task { await launchBootstrapper.bootstrapIfNeeded() }
            .onChange(of: scenePhase) { _, newPhase in
                launchBootstrapper.handleScenePhaseChange(newPhase)
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // gleis://connection?type=trainCommute&id=abc123
        guard url.scheme == "gleis" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]

        switch url.host {
        case "connection", "commute":
            selectedTab = 0
            deepLinkConnectionId = params["id"]
        case "repeat": selectedTab = 1
        case "settings": selectedTab = 2
        default: break
        }
    }
}

@MainActor
private final class AppLaunchBootstrapper: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var statusText = "Loading your commute..."

    private var hasBootstrapped = false
    private var backgroundPreloadTask: Task<Void, Never>?
    private var widgetForegroundReconcileTask: Task<Void, Never>?
    private var lastWidgetForegroundReconcileAt: Date?
    private let widgetForegroundReconcileMinimumInterval: TimeInterval = 90

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        // Never block first render on network warm-up tasks.
        isReady = true

        statusText = "Preparing saved routes..."
        let settings = SettingsManager.shared
        let trainConfig = settings.trainCommuteConfig
        let savedCommuteRoute = settings.savedCommuteRoute

        statusText = "Preloading stations and routes..."
        backgroundPreloadTask = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask(priority: .utility) {
                    _ = try? await TransportService.shared.fetchStations(for: .trainCommute)
                }

                if let start = trainConfig.startStation, let end = trainConfig.endStation, start.id != end.id {
                    group.addTask(priority: .utility) {
                        await TransportService.shared.preloadCurrentConnections(
                            from: start,
                            to: end,
                            transportType: .trainCommute,
                            count: FetchLimits.connectionBatchSize
                        )
                    }
                }

                if let home = savedCommuteRoute.homeStation,
                   let work = savedCommuteRoute.workStation,
                   home.id != work.id
                {
                    group.addTask(priority: .utility) {
                        await TransportService.shared.preloadMidnightConnections(
                            from: home,
                            to: work,
                            transportType: .trainCommute,
                            count: FetchLimits.connectionBatchSize
                        )
                    }
                    group.addTask(priority: .utility) {
                        await TransportService.shared.preloadMidnightConnections(
                            from: work,
                            to: home,
                            transportType: .trainCommute,
                            count: FetchLimits.connectionBatchSize
                        )
                    }
                }
            }
        }

        widgetForegroundReconcileTask?.cancel()
        widgetForegroundReconcileTask = Task { [weak self] in
            await self?.reconcileWidgetSnapshotOnForeground(force: true)
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        widgetForegroundReconcileTask?.cancel()
        widgetForegroundReconcileTask = Task { [weak self] in
            await self?.reconcileWidgetSnapshotOnForeground()
        }
    }

    private func reconcileWidgetSnapshotOnForeground(force: Bool = false) async {
        let now = Date()
        if !force,
           let lastAttempt = lastWidgetForegroundReconcileAt,
           now.timeIntervalSince(lastAttempt) < widgetForegroundReconcileMinimumInterval
        {
            return
        }
        lastWidgetForegroundReconcileAt = now
        _ = await WidgetSnapshotReconciler.reconcile(referenceDate: now, allowNetworkFallback: true)
    }

    deinit {
        backgroundPreloadTask?.cancel()
        widgetForegroundReconcileTask?.cancel()
    }
}

private enum WidgetSnapshotReconciler {
    private static let fetchPageSize = 12

    private struct Context {
        let config: RouteConfiguration
        let savedRoute: SavedCommuteRoute
        let reminderIds: Set<String>
        let pinnedConnectionId: String?
    }

    static func reconcile(referenceDate: Date = Date(), allowNetworkFallback: Bool) async -> Bool {
        let now = referenceDate
        let context = await MainActor.run { snapshotContext() }
        let existing = AppGroupStorage.loadPrimaryWidgetData(for: .trainCommute)

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

        let cachedConnections = await ConnectionCache.shared.load(for: .trainCommute, from: start, to: end) ?? []
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

        if allowNetworkFallback, !cacheSufficient {
            let fetchStart = max(
                now,
                (mergedConnections.map(\.departureTime).max() ?? now).addingTimeInterval(1)
            )
            if let fetched = await fetchConnectionsCoveringHorizon(
                from: start,
                to: end,
                startDate: fetchStart,
                targetEnd: targetWindow.end,
                targetCount: WidgetSnapshotBuilder.maxStoredConnectionLimit
            ), !fetched.isEmpty {
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

        let snapshotSignature = WidgetSnapshotBuilder.snapshotSignature(
            routeSignature: routeSignature,
            stateSignature: "fresh",
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
            transportType: .trainCommute,
            connections: candidates.map(WidgetSnapshotBuilder.makeWidgetConnection),
            leaveTimes: candidates.map(\.leaveTime),
            fromStationName: start.name,
            toStationName: end.name,
            updatedAt: now,
            generatedAt: now,
            coverageStart: coverage.start,
            coverageEnd: coverage.end,
            routeSignature: routeSignature,
            snapshotSignature: snapshotSignature,
            state: .fresh,
            stateMessage: candidates.isEmpty ? "No upcoming departures." : nil,
            recoveryAction: .openLiveRoute
        )
        AppGroupStorage.savePrimaryWidgetData(for: .trainCommute, data: widgetData)
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
            transportType: .trainCommute,
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
        AppGroupStorage.savePrimaryWidgetData(for: .trainCommute, data: setupData)
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
        var cursor = startDate
        let maxHops = max(4, (targetCount / max(1, fetchPageSize)) + 2)

        for _ in 0 ..< maxHops {
            if cursor > targetEnd { break }
            do {
                let page = try await TransportService.shared.fetchConnections(
                    from: start,
                    to: end,
                    transportType: .trainCommute,
                    departureTime: cursor,
                    count: fetchPageSize
                )
                guard !page.isEmpty else { break }

                var furthestDeparture = cursor
                for connection in page {
                    if seenIds.insert(connection.id).inserted {
                        allConnections.append(connection)
                    }
                    if connection.departureTime > furthestDeparture {
                        furthestDeparture = connection.departureTime
                    }
                }

                guard furthestDeparture > cursor else { break }
                cursor = furthestDeparture.addingTimeInterval(1)
                if allConnections.count >= targetCount || page.count < fetchPageSize { break }
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

private enum WidgetBackgroundRefreshScheduler {
    static let taskIdentifier = "com.veno.gleis.widget.refresh"

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

private struct AppLaunchLoadingView: View {
    let statusText: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.15, blue: 0.3), Color(red: 0.06, green: 0.22, blue: 0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Gleis")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        WidgetBackgroundRefreshScheduler.register()
        WidgetBackgroundRefreshScheduler.scheduleNext()
        return true
    }

    func applicationDidEnterBackground(_: UIApplication) {
        WidgetBackgroundRefreshScheduler.scheduleNext()
    }

    func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationManager.shared.allowLandscape ? .allButUpsideDown : .portrait
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound, .badge] }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        print("Notification tapped: \(response.notification.request.content.categoryIdentifier)")
    }
}
