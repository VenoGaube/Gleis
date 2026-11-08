import Foundation
import UserNotifications

// MARK: - DeepLinkRouter

/// Single destination for every way the app can be opened to a specific place:
/// `gleis://` URLs from the widget, and taps on scheduled notifications.
///
/// Notifications carry their destination as a `gleis://` URL in `userInfo`, so both
/// entry points resolve through the same parser.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    enum Tab: Int {
        case train = 0
        case repeatSchedules = 1
        case settings = 2
    }

    /// How long a deep-linked connection stays highlighted before the card returns to normal.
    private static let highlightDuration: TimeInterval = 4

    @Published var selectedTab: Int = Tab.train.rawValue
    @Published var highlightedConnectionId: String?

    private var highlightExpiryTask: Task<Void, Never>?

    private init() {}

    // MARK: - Entry Points

    func handle(_ url: URL) {
        guard url.scheme == "gleis" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]

        switch url.host {
        case "connection", "commute":
            select(.train)
            highlight(connectionId: params["id"])
        case "setup":
            // The route pickers live at the top of the Train tab.
            select(.train)
        case "repeat":
            select(.repeatSchedules)
        case "settings":
            select(.settings)
        default:
            break
        }
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[NotificationPayload.deepLinkKey] as? String, let url = URL(string: raw) else { return }
        handle(url)
    }

    // MARK: - Navigation

    private func select(_ tab: Tab) {
        selectedTab = tab.rawValue
    }

    private func highlight(connectionId: String?) {
        highlightExpiryTask?.cancel()
        highlightedConnectionId = connectionId
        guard connectionId != nil else { return }

        highlightExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.highlightDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.highlightedConnectionId = nil
        }
    }
}

// MARK: - NotificationPayload

/// Keys and destinations attached to scheduled notifications so a tap can route the
/// user to the journey the notification is about.
enum NotificationPayload {
    static let deepLinkKey = "gleisDeepLink"

    static func connectionDeepLink(id: String) -> String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return "gleis://connection?id=\(encoded)"
    }

    static let repeatScheduleDeepLink = "gleis://repeat"
}
