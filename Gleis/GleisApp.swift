import SwiftUI
import UserNotifications

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
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var launchBootstrapper = AppLaunchBootstrapper()

    init() {
        // Configure status bar and navigation bar appearance for proper safe area handling
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        if DebugLaunchOptions.skipOnboarding { Self.markOnboardingCompleted() }
    }

    private static func markOnboardingCompleted() {
        let settingsManager = SettingsManager.shared
        guard !settingsManager.appSettings.hasCompletedOnboarding else { return }
        var settings = settingsManager.appSettings
        settings.hasCompletedOnboarding = true
        settingsManager.updateAppSettings(settings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                selectedTab: $router.selectedTab,
                deepLinkConnectionId: $router.highlightedConnectionId
            )
            .task { await launchBootstrapper.bootstrapIfNeeded() }
            .onChange(of: scenePhase) { _, newPhase in
                launchBootstrapper.handleScenePhaseChange(newPhase)
            }
            .onOpenURL { router.handle($0) }
        }
    }
}

/// Warms caches in the background after first render. Nothing here gates the UI —
/// the app shows real content immediately and fills in as these tasks land.
@MainActor
private final class AppLaunchBootstrapper: ObservableObject {
    private var hasBootstrapped = false
    private var backgroundPreloadTask: Task<Void, Never>?
    private var widgetForegroundReconcileTask: Task<Void, Never>?
    private var lastWidgetForegroundReconcileAt: Date?
    private let widgetForegroundReconcileMinimumInterval: TimeInterval = 90

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        backgroundPreloadTask = Task.detached(priority: .utility) {
            _ = try? await TransportService.shared.fetchStations()
        }

        widgetForegroundReconcileTask?.cancel()
        widgetForegroundReconcileTask = Task { [weak self] in
            await self?.reconcileWidgetSnapshotOnForeground(force: true)
        }

        if let routeNames = DebugLaunchOptions.routeNames {
            await saveLaunchRoute(fromName: routeNames.from, toName: routeNames.to)
        }
    }

    private func saveLaunchRoute(fromName: String, toName: String) async {
        do {
            async let fromMatches = TransportService.shared.searchStations(matching: fromName)
            async let toMatches = TransportService.shared.searchStations(matching: toName)
            guard let start = try await fromMatches.first, let end = try await toMatches.first else {
                print("DebugLaunchOptions: no station found for route \(fromName)|\(toName)")
                return
            }
            let settingsManager = SettingsManager.shared
            var config = settingsManager.trainCommuteConfig
            config.startStation = start
            config.endStation = end
            settingsManager.updateConfig(config)
        } catch {
            print("DebugLaunchOptions: station search failed for route \(fromName)|\(toName): \(error)")
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
        // Cache only: the view model's refresh on the same launch or foreground owns the network fetch.
        _ = await WidgetSnapshotReconciler.reconcile(referenceDate: now, allowNetworkFallback: false)
    }

    deinit {
        backgroundPreloadTask?.cancel()
        widgetForegroundReconcileTask?.cancel()
    }
}

// MARK: - DebugLaunchOptions

/// Launch arguments that put the app in a known state for CI screenshots. Release builds ignore them.
enum DebugLaunchOptions {
    static let skipOnboarding: Bool = hasFlag("-GleisSkipOnboarding")

    static let routeNames: (from: String, to: String)? = {
        guard let value = argumentValue(after: "-GleisRoute") else { return nil }
        let names = value.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count == 2, !names[0].isEmpty, !names[1].isEmpty else {
            print("DebugLaunchOptions: -GleisRoute expects \"From|To\", got \(value)")
            return nil
        }
        return (from: names[0], to: names[1])
    }()

    static let initialTab: Int? = {
        guard let value = argumentValue(after: "-GleisTab") else { return nil }
        guard let tab = Int(value).flatMap(DeepLinkRouter.Tab.init(rawValue:)) else {
            print("DebugLaunchOptions: -GleisTab expects 0, 1 or 2, got \(value)")
            return nil
        }
        return tab.rawValue
    }()

    static let jumpHoursAhead: Double? = {
        guard let value = argumentValue(after: "-GleisJumpHours") else { return nil }
        guard let hours = Double(value), hours > 0, hours <= maximumJumpHours else {
            print("DebugLaunchOptions: -GleisJumpHours expects hours in (0, \(maximumJumpHours)], got \(value)")
            return nil
        }
        return hours
    }()

    static let openFirstDetail: Bool = hasFlag("-GleisOpenDetail")

    // Matches the departure time sheet, which offers dates up to seven days ahead.
    private static let maximumJumpHours: Double = 7 * 24

    private static func hasFlag(_ flag: String) -> Bool {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains(flag)
        #else
            return false
        #endif
    }

    private static func argumentValue(after flag: String) -> String? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        #else
            return nil
        #endif
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

        // Start the route's first fetch at the earliest point the app has one.
        //
        // The provider needs 5-8s to answer, which makes that request the launch
        // critical path — longer than everything else put together. Starting it here
        // runs it alongside SwiftUI startup instead of after it; the view model claims
        // this same in-flight task rather than issuing a second one.
        let config = SettingsManager.shared.trainCommuteConfig
        if let start = config.startStation, let end = config.endStation, start.id != end.id {
            TransportService.shared.prewarmConnections(from: start, to: end)
        }

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

    // `UIApplicationDelegate` conformance is main-actor isolated, so the router
    // (which is too) is reachable directly.
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        DeepLinkRouter.shared.handleNotificationResponse(response)
    }
}
