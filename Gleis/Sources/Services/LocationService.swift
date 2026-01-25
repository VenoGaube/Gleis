import Combine
import CoreLocation
import Foundation

// MARK: - LocationService

final class LocationService: NSObject, LocationServiceProtocol, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var locationPublisher: AnyPublisher<CLLocation?, Never> { $currentLocation.eraseToAnyPublisher() }

    private let locationManager = CLLocationManager()

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50 // Only update when user moves >50 meters
        self.authorizationStatus = locationManager.authorizationStatus
    }

    func requestAuthorization() { locationManager.requestWhenInUseAuthorization() }

    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return }
        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() { locationManager.stopUpdatingLocation() }

    func findNearestStation(from stations: [Station]) -> Station? {
        guard let location = currentLocation else { return nil }
        return stations.filter { $0.coordinate != nil }.min {
            let loc1 = CLLocation(latitude: $0.coordinate!.latitude, longitude: $0.coordinate!.longitude)
            let loc2 = CLLocation(latitude: $1.coordinate!.latitude, longitude: $1.coordinate!.longitude)
            return location.distance(from: loc1) < location.distance(from: loc2)
        }
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
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus ==
            .authorizedAlways { startUpdatingLocation() }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }

    func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
}
