import BackgroundTasks
import SwiftUI
import UserNotifications
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
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }.onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Force widget refresh when app becomes active (e.g., after unlocking phone)
                WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
            case .background:
                // Schedule background refresh for fresh widget data
                WidgetRefreshService.shared.scheduleBackgroundRefresh()
            default: break
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

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        statusText = "Preparing saved routes..."
        _ = SettingsManager.shared.savedCommuteRoute

        statusText = "Preparing station data..."
        _ = Task(priority: .utility) {
            _ = try? await TransportService.shared.fetchStations(for: .trainCommute)
        }

        statusText = "Preparing location..."
        LocationService.shared.startUpdatingLocation()

        try? await Task.sleep(nanoseconds: 900_000_000)
        isReady = true
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
        registerBackgroundTasks()
        return true
    }

    func applicationDidEnterBackground(_: UIApplication) {
        // Schedule background refresh for fresh widget data
        WidgetRefreshService.shared.scheduleBackgroundRefresh()
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

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: WidgetRefreshService.taskIdentifier, using: nil) {
            task in self.handleWidgetRefresh(task: task as! BGAppRefreshTask)
        }
    }

    private func handleWidgetRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh before handling this one
        WidgetRefreshService.shared.scheduleBackgroundRefresh()

        let refreshTask = Task { await WidgetRefreshService.shared.refreshWidgetData() }

        task.expirationHandler = { refreshTask.cancel() }

        Task {
            await refreshTask.value
            task.setTaskCompleted(success: true)
        }
    }
}
