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

    init() {
        // Configure status bar and navigation bar appearance for proper safe area handling
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab, deepLinkConnectionId: $deepLinkConnectionId)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Force widget refresh when app becomes active (e.g., after unlocking phone)
                WidgetCenter.shared.reloadTimelines(ofKind: "GleisWidget")
            case .background:
                // Schedule background refresh for fresh widget data
                WidgetRefreshService.shared.scheduleBackgroundRefresh()
            default:
                break
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
        case "repeat":
            selectedTab = 1
        case "settings":
            selectedTab = 2
        default:
            break
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
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        print("Notification tapped: \(response.notification.request.content.categoryIdentifier)")
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: WidgetRefreshService.taskIdentifier,
            using: nil
        ) { task in
            self.handleWidgetRefresh(task: task as! BGAppRefreshTask)
        }
    }

    private func handleWidgetRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh before handling this one
        WidgetRefreshService.shared.scheduleBackgroundRefresh()

        let refreshTask = Task {
            await WidgetRefreshService.shared.refreshWidgetData()
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }

        Task {
            await refreshTask.value
            task.setTaskCompleted(success: true)
        }
    }
}
