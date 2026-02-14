import Combine
import CoreLocation
import Foundation

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
    func searchStationsNearby(
        latitude: Double, longitude: Double, transportType: TransportType
    ) async throws -> [Station]
    func fetchStationBoard(stationId: String, directionId: String?) async throws -> [StationBoardEntry]
}

// MARK: - LocationServiceProtocol

protocol LocationServiceProtocol {
    var currentLocation: CLLocation? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationPublisher: AnyPublisher<CLLocation?, Never> { get }
    func requestAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func findNearestStation(from stations: [Station]) -> Station?
    func distance(to station: Station) -> CLLocationDistance?
    func calculateDistances(to stations: [Station]) -> [(station: Station, distance: CLLocationDistance)]
}

// MARK: - NotificationServiceProtocol

protocol NotificationServiceProtocol {
    func requestAuthorization() async throws -> Bool
    func scheduleNotification(
        for connection: TrainConnection, config: RouteConfiguration, type: NotificationType, fromStationId: String?
    )
        async throws
    func cancelNotification(id: String)
    func cancelAllNotifications()
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
    case locationNotAvailable
    case notificationPermissionDenied
    case storageError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case let .networkError(msg): "Network error: \(msg)"
        case let .apiError(msg): "API error: \(msg)"
        case .stationNotFound: "Station not found"
        case .noConnectionsAvailable: "No connections available"
        case .noRouteConfigured: "No route configured"
        case .locationNotAvailable: "Location unavailable"
        case .notificationPermissionDenied: "Notifications disabled"
        case let .storageError(msg): "Storage error: \(msg)"
        case let .unknown(msg): msg
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .networkError: "Check your internet connection"
        case .apiError: "The server may be temporarily unavailable"
        case .noRouteConfigured: "Select start and end stations"
        case .locationNotAvailable: "Enable location in Settings"
        case .notificationPermissionDenied: "Enable in device Settings"
        default: "Try again later"
        }
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
