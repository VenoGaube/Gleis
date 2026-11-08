import Foundation

// MARK: - FetchLimits

enum FetchLimits {
    /// Connections asked for per request.
    ///
    /// The gate caps every TripSearch response at six or seven trips and ignores
    /// `numF` above that — measured identical for 15, 20 and 30, with and without
    /// a passlist — so a bigger number buys nothing and the server charges roughly
    /// 0.8s per trip it computes. Asking for what we actually get keeps latency
    /// down and, more importantly, stops `count >= connectionBatchSize` tests from
    /// being permanently false.
    static let connectionBatchSize = 7
    /// The ceiling the gate enforces on a single response, regardless of `numF`.
    /// Treat a page of this size as "there is probably more", never as "that is all".
    static let gateMaxConnectionsPerResponse = 7
    /// Round trips a coverage-driven fetch may spend before giving up. Each page is
    /// a 3-8s server round trip, so this is a latency budget as much as a page count.
    static let maxCoveragePages = 4
    static let stationSearchCount = 30
    /// Size of the browsable/offline station pool fetched with an empty query.
    static let stationBrowseCount = 100
    static let stationResolveCandidateCount = 5
    static let commuteSuggestionConnectionCount = 5
}

struct ConnectionPage: Sendable {
    let connections: [TrainConnection]
    let forwardCursor: String?
    let backwardCursor: String?
    let requestDate: String
    let requestTime: String
    let pageSize: Int
}

/// What a coverage fetch is trying to reach. The gate hands back six or seven trips
/// per response whatever we ask for, so callers that need a span of timetable — a
/// whole morning, a day's departures — have to say so and let the fetch page for it.
struct ConnectionCoverage: Sendable {
    /// Keep paging until at least this many connections have been collected.
    let minimumCount: Int
    /// Keep paging until a departure at or after this instant has been seen.
    /// `nil` means count alone decides.
    let throughDeparture: Date?
    /// Discard connections departing before this instant. Page 1 of a midnight-seeded
    /// search routinely leads with the previous day's late train.
    let notBefore: Date?
    /// Discard connections departing at or after this instant.
    let notAfter: Date?
    /// Total wall-clock budget for the whole run.
    ///
    /// Page count alone does not bound this: pages get slower the deeper they go, and
    /// the provider has answered anywhere between 3s and 15s for one page, so four
    /// pages is somewhere between 12s and a minute. Whatever has arrived when the
    /// budget runs out is returned.
    let budget: TimeInterval

    init(
        minimumCount: Int,
        throughDeparture: Date? = nil,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        budget: TimeInterval = 25
    ) {
        self.minimumCount = minimumCount
        self.throughDeparture = throughDeparture
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.budget = budget
    }
}

/// A first page started before anything asked for it, with the seed it was started at.
///
/// The seed matters: whoever consumes this inherits it as the pagination anchor, so
/// "load more" continues the same search rather than starting a second one.
struct PrewarmedConnectionsPage: Sendable {
    let page: ConnectionPage
    let seedDateTime: Date
}

/// The accumulated result of a coverage fetch, with the cursor left where paging stopped.
struct ConnectionCoverageResult: Sendable {
    let connections: [TrainConnection]
    let forwardCursor: String?
    let seedDateTime: Date
}

// MARK: - TransportServiceProtocol

protocol TransportServiceProtocol: Sendable {
    func fetchConnections(from: Station, to: Station, transportType: TransportType) async throws -> [TrainConnection]
    func fetchConnections(
        from: Station, to: Station, transportType: TransportType, departureTime: Date, count: Int
    ) async throws -> [TrainConnection]
    func fetchConnectionsPage(
        from: Station,
        to: Station,
        transportType: TransportType,
        seedDateTime: Date,
        pageSize: Int,
        cursor: String?
    ) async throws -> ConnectionPage
    func fetchConnectionsCovering(
        from: Station,
        to: Station,
        transportType: TransportType,
        seedDateTime: Date,
        coverage: ConnectionCoverage,
        onPage: (@Sendable ([TrainConnection]) async -> Void)?
    ) async throws -> ConnectionCoverageResult
    func fetchMoreConnections(
        from: Station, to: Station, transportType: TransportType, after lastDeparture: Date
    ) async throws -> [TrainConnection]
    /// Starts the first connections fetch for a route without waiting for a consumer.
    ///
    /// Called at process launch so the provider's 5-8s round trip overlaps SwiftUI
    /// startup instead of beginning after it.
    func prewarmConnections(from: Station, to: Station, transportType: TransportType)
    /// Hands over a prewarmed fetch for this route, awaiting it if still in flight.
    /// Returns nil when there is none, or when it is too old to still be live data.
    func claimPrewarmedConnections(
        from: Station, to: Station, transportType: TransportType
    ) async throws -> PrewarmedConnectionsPage?
    func fetchStations(for transportType: TransportType) async throws -> [Station]
    func searchStations(matching query: String, transportType: TransportType) async throws -> [Station]
}

// MARK: - NotificationServiceProtocol

protocol NotificationServiceProtocol: Sendable {
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
    func cancelServiceAlertNotifications(reminderId: String) async
    func cancelAllCommuteNotifications() async
    func scheduleCommuteNotification(
        route: SavedCommuteRoute, day: Weekday, schedule: DaySchedule, direction: CommuteDirection,
        config: RouteConfiguration, occurrence: CommuteOccurrencePlanner.Occurrence, occurrenceIndex: Int
    ) async throws
}

// MARK: - StorageServiceProtocol

protocol StorageServiceProtocol: Sendable {
    func save(_ value: some Codable, forKey key: String) throws
    func load<T: Codable>(forKey key: String) throws -> T?
    func delete(forKey key: String) throws
}

// MARK: - NotificationType

enum NotificationType { case fiveMinuteWarning, exactTime }

// MARK: - GleisError

enum GleisError: LocalizedError {
    case networkError(String)
    /// The device has no usable connection. Distinguished from `networkError` so the
    /// UI can say so without having to inspect a message string.
    case offline(String)
    /// The request was sent but no response arrived in time.
    case timeout(String)
    case apiError(String)
    case stationNotFound
    case noConnectionsAvailable
    case noRouteConfigured
    case notificationPermissionDenied
    case storageError(String)
    /// The moment a reminder would have fired is already in the past.
    case reminderTimeAlreadyPassed
    case unknown(String)

    static func from(_ error: Error) -> GleisError {
        if let gleisError = error as? GleisError { return gleisError }
        if let urlError = error as? URLError { return from(urlError) }
        return .unknown(error.localizedDescription)
    }

    /// Classifies by `URLError.Code` rather than by `localizedDescription`.
    /// The description is localized, so substring matching on it silently stopped
    /// working on any device not set to English.
    static func from(_ urlError: URLError) -> GleisError {
        let message = urlError.localizedDescription
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .callIsActive:
            return .offline(message)
        case .timedOut:
            return .timeout(message)
        default:
            return .networkError(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case let .networkError(msg): "Network error: \(msg)"
        case let .offline(msg): "Offline: \(msg)"
        case let .timeout(msg): "Timed out: \(msg)"
        case let .apiError(msg): "API error: \(msg)"
        case .stationNotFound: "Station not found"
        case .noConnectionsAvailable: "No connections available"
        case .noRouteConfigured: "No route configured"
        case .notificationPermissionDenied: "Notifications disabled"
        case .reminderTimeAlreadyPassed: "Departure is too soon"
        case let .storageError(msg): "Storage error: \(msg)"
        case let .unknown(msg): msg
        }
    }

    var userFacingTitle: String {
        switch self {
        case .networkError:
            return "Connection Problem"
        case .timeout:
            return "Request Timed Out"
        case .offline:
            return "No Internet Connection"
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
        case .reminderTimeAlreadyPassed:
            return "Departure Too Soon"
        case .storageError:
            return "Data Error"
        case .unknown:
            return "Something Went Wrong"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .networkError:
            return "We couldn't reach the service right now. Please try again shortly."
        case .timeout:
            return "The server is taking too long to respond. We will keep trying in the background."
        case .offline:
            return "You appear to be offline. Check your connection and try again."
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
        case .reminderTimeAlreadyPassed:
            return "It is already time to leave for this train, so there is nothing left to remind you about."
        case .storageError:
            return "Saved data couldn't be loaded. Please try again."
        case .unknown:
            return "An unexpected error occurred. Please try again."
        }
    }

    var isTransientOverload: Bool {
        switch self {
        case .timeout:
            return true
        case .apiError:
            return isRateLimitedLike || isServerOverloadLike
        default:
            return false
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .networkError, .offline, .timeout: "Check your internet connection"
        case .apiError: "The server may be temporarily unavailable"
        case .noRouteConfigured: "Select start and end stations"
        case .notificationPermissionDenied: "Enable in device Settings"
        default: "Try again later"
        }
    }

    /// Only ever matched against strings this app builds itself (e.g. "HTTP 429"),
    /// never against a localized system message.
    private var rawText: String {
        switch self {
        case let .apiError(message), let .storageError(message), let .unknown(message):
            return message.lowercased()
        default:
            return ""
        }
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

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var value: T? {
        if case let .loaded(v) = self { return v }
        return nil
    }
}
