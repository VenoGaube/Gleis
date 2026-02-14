import Combine
import CoreLocation
import Foundation
import WidgetKit

// MARK: - LocationService

final class LocationService: NSObject, LocationServiceProtocol, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdatingLocation = false

    var locationPublisher: AnyPublisher<CLLocation?, Never> { $currentLocation.eraseToAnyPublisher() }

    private let locationManager = CLLocationManager()

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50 // Only update when user moves >50 meters
        authorizationStatus = locationManager.authorizationStatus
    }

    func requestAuthorization() {
        // Request "Always" for reliable background location updates and widget refreshes
        locationManager.requestAlwaysAuthorization()
    }

    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            isUpdatingLocation = false
            return
        }
        locationManager.startUpdatingLocation()
        // Use significant location changes for battery-efficient background updates (~500m movement)
        locationManager.startMonitoringSignificantLocationChanges()
        isUpdatingLocation = true

        // Enable background updates when authorized always (for widget refreshes)
        if authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = true
        }
    }

    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        isUpdatingLocation = false
    }

    func calculateDistances(to stations: [Station]) -> [(station: Station, distance: CLLocationDistance)] {
        guard let location = currentLocation else { return [] }
        return stations.compactMap { station -> (station: Station, distance: CLLocationDistance)? in
            guard let coordinate = station.coordinate else { return nil }
            let stationLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return (station: station, distance: location.distance(from: stationLocation))
        }.sorted { $0.distance < $1.distance }
    }

    func findNearestStation(from stations: [Station]) -> Station? {
        calculateDistances(to: stations).first?.station
    }

    func distance(to station: Station) -> CLLocationDistance? {
        guard let location = currentLocation, let coordinate = station.coordinate else { return nil }
        let stationLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return location.distance(from: stationLocation)
    }
}

// MARK: CLLocationManagerDelegate + LocationService

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdatingLocation()
        } else {
            isUpdatingLocation = false
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last

        // Trigger widget refresh and auto-swap on location updates
        Task {
            await performBackgroundAutoSwap()
            await WidgetRefreshService.shared.refreshWidgetData()
        }
    }

    /// Automatically swap stations to keep nearest as start (runs in background)
    private func performBackgroundAutoSwap() async {
        await MainActor.run {
            let settingsManager = SettingsManager.shared
            let config = settingsManager.trainCommuteConfig

            // Only auto-swap if:
            // 1. Auto-selection is enabled
            // 2. User hasn't manually overridden
            // 3. Both stations are set
            guard settingsManager.appSettings.useLocationForStartStation,
                  !config.isStartStationManuallySelected,
                  let start = config.startStation,
                  let end = config.endStation,
                  let distanceToStart = distance(to: start),
                  let distanceToEnd = distance(to: end)
            else { return }

            // If end station is closer than start, swap them
            if distanceToEnd < distanceToStart {
                var updatedConfig = config
                updatedConfig.startStation = end
                updatedConfig.endStation = start
                settingsManager.updateConfig(updatedConfig)
                print("🔄 Background auto-swap: Swapped stations based on location")
            }
        }
    }

    func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
}
