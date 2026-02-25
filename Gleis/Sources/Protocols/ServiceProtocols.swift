import Foundation

// MARK: - FetchLimits

enum FetchLimits {
    static let connectionBatchSize = 6
    static let stationSearchCount = 25
    static let stationResolveCandidateCount = 5
    static let widgetRefreshConnectionCount = 5
    static let commuteSuggestionConnectionCount = 5
}

// MARK: - TransportServiceProtocol

protocol TransportServiceProtocol: Sendable {
    func fetchConnections(from: Station, to: Station, transportType: TransportType) async throws -> [TrainConnection]
    func fetchConnections(
        from: Station, to: Station, transportType: TransportType, departureTime: Date, count: Int
    ) async throws -> [TrainConnection]
    func fetchConnectionsFromMidnight(
        from: Station, to: Station, transportType: TransportType
    ) async throws -> [TrainConnection]
    func fetchMoreConnections(
        from: Station, to: Station, transportType: TransportType, after lastDeparture: Date
    ) async throws -> [TrainConnection]
    func fetchStations(for transportType: TransportType) async throws -> [Station]
    func searchStations(matching query: String, transportType: TransportType) async throws -> [Station]
}

// MARK: - NotificationServiceProtocol

protocol NotificationServiceProtocol {
    func requestAuthorization() async throws -> Bool
    func scheduleNotification(
        for connection: TrainConnection, config: RouteConfiguration, type: NotificationType, fromStationId: String?
    )
        async throws
    func scheduleServiceAlertNotification(
        for connection: TrainConnection,
        alert: ServiceAlert,
        reminderId: String
    ) async throws
    func cancelNotification(id: String)
    func cancelServiceAlertNotifications(reminderId: String)
    func cancelCommuteNotification(day: Weekday, direction: CommuteDirection)
    func cancelAllCommuteNotifications()
    func scheduleCommuteNotification(
        route: SavedCommuteRoute, day: Weekday, schedule: DaySchedule, direction: CommuteDirection,
        config: RouteConfiguration
    ) async throws
}

// MARK: - StorageServiceProtocol

protocol StorageServiceProtocol {
    func save(_ value: some Codable, forKey key: String) throws
    func load<T: Codable>(forKey key: String) throws -> T?
    func delete(forKey key: String) throws
}

// MARK: - NotificationType

enum NotificationType { case fiveMinuteWarning, exactTime }

// MARK: - GleisError

enum GleisError: LocalizedError {
    case networkError(String)
    case apiError(String)
    case stationNotFound
    case noConnectionsAvailable
    case noRouteConfigured
    case notificationPermissionDenied
    case storageError(String)
    case unknown(String)

    static func from(_ error: Error) -> GleisError {
        if let gleisError = error as? GleisError { return gleisError }
        if let urlError = error as? URLError {
            return .networkError(urlError.localizedDescription)
        }
        return .unknown(error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case let .networkError(msg): "Network error: \(msg)"
        case let .apiError(msg): "API error: \(msg)"
        case .stationNotFound: "Station not found"
        case .noConnectionsAvailable: "No connections available"
        case .noRouteConfigured: "No route configured"
        case .notificationPermissionDenied: "Notifications disabled"
        case let .storageError(msg): "Storage error: \(msg)"
        case let .unknown(msg): msg
        }
    }

    var userFacingTitle: String {
        switch self {
        case .networkError:
            if isTimeoutLike { return "Request Timed Out" }
            if isOfflineLike { return "No Internet Connection" }
            return "Connection Problem"
        case .apiError:
            if isRateLimitedLike || isServerOverloadLike { return "Service Is Busy" }
            return "Service Temporarily Unavailable"
        case .stationNotFound:
            return "Station Not Found"
        case .noConnectionsAvailable:
            return "No Connections Available"
        case .noRouteConfigured:
            return "Route Not Configured"
        case .notificationPermissionDenied:
            return "Notifications Disabled"
        case .storageError:
            return "Data Error"
        case .unknown:
            return "Something Went Wrong"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .networkError:
            if isTimeoutLike {
                return "The server is taking too long to respond. We will keep trying in the background."
            }
            if isOfflineLike {
                return "You appear to be offline. Check your connection and try again."
            }
            return "We couldn't reach the service right now. Please try again shortly."
        case .apiError:
            if isRateLimitedLike || isServerOverloadLike {
                return "Travel service is under heavy load right now. Showing latest available data and retrying automatically."
            }
            return "The travel service returned an unexpected response. Please try again in a moment."
        case .stationNotFound:
            return "We couldn't resolve one of the selected stations. Please choose a station from the list."
        case .noConnectionsAvailable:
            return "No departures are available for this route right now."
        case .noRouteConfigured:
            return "Select both start and destination stations to load departures."
        case .notificationPermissionDenied:
            return "Enable notifications in Settings to receive journey alerts."
        case .storageError:
            return "Saved data couldn't be loaded. Please try again."
        case .unknown:
            return "An unexpected error occurred. Please try again."
        }
    }

    var isTransientOverload: Bool {
        switch self {
        case .networkError:
            return isTimeoutLike
        case .apiError:
            return isRateLimitedLike || isServerOverloadLike
        default:
            return false
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .networkError: "Check your internet connection"
        case .apiError: "The server may be temporarily unavailable"
        case .noRouteConfigured: "Select start and end stations"
        case .notificationPermissionDenied: "Enable in device Settings"
        default: "Try again later"
        }
    }

    private var rawText: String {
        switch self {
        case let .networkError(message), let .apiError(message), let .storageError(message), let .unknown(message):
            return message.lowercased()
        default:
            return ""
        }
    }

    private var isTimeoutLike: Bool {
        rawText.contains("timed out") || rawText.contains("timeout") || rawText.contains("request timed out")
    }

    private var isOfflineLike: Bool {
        rawText.contains("offline")
            || rawText.contains("not connected")
            || rawText.contains("internet connection appears to be offline")
    }

    private var isRateLimitedLike: Bool {
        rawText.contains("http 429") || rawText.contains("rate limit")
    }

    private var isServerOverloadLike: Bool {
        rawText.contains("http 500")
            || rawText.contains("http 502")
            || rawText.contains("http 503")
            || rawText.contains("http 504")
            || rawText.contains("service unavailable")
    }
}

// MARK: - LoadingState

enum LoadingState<T> {
    case idle, loading
    case loaded(T)
    case error(GleisError)
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var value: T? {
        if case let .loaded(v) = self { return v }
        return nil
    }
}
