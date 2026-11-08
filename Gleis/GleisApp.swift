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
