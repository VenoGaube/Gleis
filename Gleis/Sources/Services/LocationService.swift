import Combine
import CoreLocation
import Foundation
import WidgetKit

// MARK: - CommuteDirectionService

final class CommuteDirectionService {
    static let shared = CommuteDirectionService()

    // Require a meaningful distance lead and stable reading window before swapping commute direction.
    private let minimumLeadDistanceMeters: CLLocationDistance = 1_200
    private let stabilizationWindow: TimeInterval = 90

    private var activePairKey: String?
    private var pendingDirection: CommuteDirection?
    private var pendingSince: Date?

    private init() {}

    func reset() {
        activePairKey = nil
        clearPending()
    }

    func resolveDirection(
        home: Station,
        work: Station,
        distanceToHome: CLLocationDistance,
        distanceToWork: CLLocationDistance,
        currentStart: Station?,
        currentEnd: Station?,
        now: Date = Date()
    ) -> CommuteDirection {
        let pairKey = makePairKey(homeId: home.id, workId: work.id)
        if activePairKey != pairKey {
            activePairKey = pairKey
            clearPending()
        }

        let candidate: CommuteDirection = distanceToHome <= distanceToWork ? .toWork : .toHome
        let current = currentDirection(home: home, work: work, currentStart: currentStart, currentEnd: currentEnd)
        let distanceLead = abs(distanceToHome - distanceToWork)

        guard let current else {
            clearPending()
            return candidate
        }

        guard candidate != current else {
            clearPending()
            return current
        }

        guard distanceLead >= minimumLeadDistanceMeters else {
            clearPending()
            return current
        }

        if pendingDirection != candidate {
            pendingDirection = candidate
            pendingSince = now
            return current
        }

        if let pendingSince, now.timeIntervalSince(pendingSince) >= stabilizationWindow {
            clearPending()
            return candidate
        }

        return current
    }

    private func currentDirection(
        home: Station,
        work: Station,
        currentStart: Station?,
        currentEnd: Station?
    ) -> CommuteDirection? {
        if currentStart?.id == home.id, currentEnd?.id == work.id { return .toWork }
        if currentStart?.id == work.id, currentEnd?.id == home.id { return .toHome }
        return nil
    }

    private func makePairKey(homeId: String, workId: String) -> String { [homeId, workId].sorted().joined(separator: "_") }

    private func clearPending() {
        pendingDirection = nil
        pendingSince = nil
    }
}

// MARK: - LocationService

final class LocationService: NSObject, LocationServiceProtocol, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdatingLocation = false

    private let locationManager = CLLocationManager()
    private let commuteDirectionService = CommuteDirectionService.shared

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50 // Avoid excessive updates while still tracking commute relevance
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

            guard settingsManager.appSettings.useLocationForStartStation,
                  settingsManager.appSettings.useSmartStationSwap,
                  !config.isStartStationManuallySelected
            else { return }

            if let directedStations = preferredCommuteDirection(
                route: settingsManager.savedCommuteRoute,
                currentStart: config.startStation,
                currentEnd: config.endStation
            ) {
                let (preferredStart, preferredEnd) = directedStations
                if config.startStation?.id != preferredStart.id || config.endStation?.id != preferredEnd.id {
                    var updatedConfig = config
                    updatedConfig.startStation = preferredStart
                    updatedConfig.endStation = preferredEnd
                    settingsManager.updateConfig(updatedConfig)
                    print("🔄 Background auto-swap: Applied commute direction from saved route")
                }
                return
            }

            guard let start = config.startStation,
                  let end = config.endStation,
                  let distanceToStart = distance(to: start),
                  let distanceToEnd = distance(to: end)
            else { return }

            let excluded = settingsManager.appSettings.autoSelectionPreferences.excludedStationIds
            if excluded.contains(start.id), !excluded.contains(end.id) {
                var updatedConfig = config
                updatedConfig.startStation = end
                updatedConfig.endStation = start
                settingsManager.updateConfig(updatedConfig)
                print("🔄 Background auto-swap: Reordered away from excluded auto-start station")
                return
            }
            if excluded.contains(end.id) { return }

            if let preferredId = preferredStationIdForCurrentLocation(
                preferences: settingsManager.appSettings.autoSelectionPreferences
            ) {
                if preferredId == end.id, preferredId != start.id {
                    var updatedConfig = config
                    updatedConfig.startStation = end
                    updatedConfig.endStation = start
                    settingsManager.updateConfig(updatedConfig)
                    print("🔄 Background auto-swap: Applied preferred auto-start station")
                    return
                }
                if preferredId == start.id { return }
            }

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

    @MainActor
    private func preferredCommuteDirection(
        route: SavedCommuteRoute,
        currentStart: Station?,
        currentEnd: Station?
    ) -> (Station, Station)? {
        guard let home = route.homeStation, let work = route.workStation, home.id != work.id else {
            commuteDirectionService.reset()
            return nil
        }
        guard shouldUseSavedCommuteDirection(home: home, work: work, currentStart: currentStart, currentEnd: currentEnd)
        else {
            commuteDirectionService.reset()
            return nil
        }
        guard let distanceToHome = distance(to: home), let distanceToWork = distance(to: work) else { return nil }

        let direction = commuteDirectionService.resolveDirection(
            home: home,
            work: work,
            distanceToHome: distanceToHome,
            distanceToWork: distanceToWork,
            currentStart: currentStart,
            currentEnd: currentEnd
        )

        guard let start = route.fromStation(for: direction), let end = route.toStation(for: direction) else { return nil }

        let excluded = SettingsManager.shared.appSettings.autoSelectionPreferences.excludedStationIds
        if excluded.contains(start.id) { return nil }
        return (start, end)
    }

    @MainActor
    private func shouldUseSavedCommuteDirection(
        home: Station,
        work: Station,
        currentStart: Station?,
        currentEnd: Station?
    ) -> Bool {
        let currentIds = Set([currentStart?.id, currentEnd?.id].compactMap { $0 })
        if currentIds.isEmpty { return true }
        let commuteIds: Set<String> = [home.id, work.id]
        return currentIds.isSubset(of: commuteIds)
    }

    @MainActor
    private func preferredStationIdForCurrentLocation(preferences: AutoSelectionPreferences) -> String? {
        guard let location = currentLocation else { return nil }
        let preferredId = preferences.preferredStationId(near: location)
        guard let preferredId, !preferences.excludedStationIds.contains(preferredId) else { return nil }
        return preferredId
    }

    func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
}
