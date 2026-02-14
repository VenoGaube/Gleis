import Combine
import CoreLocation
import Foundation

@MainActor
final class NearbyStationService: ObservableObject {
    @Published private(set) var nearbyStations: [Station] = []
    @Published private(set) var stationDistances: [String: Double] = [:]
    @Published private(set) var stationSuggestedTravelTimes: [String: Int] = [:]

    private let transportService: TransportServiceProtocol
    private let locationService: LocationService
    private var lastLocation: CLLocation?
    private var lastUpdate: Date?

    private let distanceThreshold: CLLocationDistance = 500
    private let foregroundTimeThreshold: TimeInterval = 300
    private let backgroundTimeThreshold: TimeInterval = 7200

    init(
        transportService: TransportServiceProtocol = TransportService.shared,
        locationService: LocationService = LocationService.shared
    ) {
        self.transportService = transportService
        self.locationService = locationService
    }

    func refreshIfNeeded(transportType: TransportType, isBackground: Bool = false) async {
        guard let location = locationService.currentLocation else {
            nearbyStations = []
            stationDistances = [:]
            stationSuggestedTravelTimes = [:]
            return
        }

        let timeThreshold = isBackground ? backgroundTimeThreshold : foregroundTimeThreshold
        if let lastLoc = lastLocation, let lastUp = lastUpdate {
            let distanceChange = location.distance(from: lastLoc)
            let timeElapsed = Date().timeIntervalSince(lastUp)
            guard distanceChange > distanceThreshold || timeElapsed > timeThreshold else { return }
        }

        do {
            let nearby = try await transportService.searchStationsNearby(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                transportType: transportType
            )
            var distances = Dictionary(
                uniqueKeysWithValues: nearby.compactMap { station in
                    station.nearbyDistanceMeters.map { (station.id, $0) }
                }
            )
            stationSuggestedTravelTimes = Dictionary(
                uniqueKeysWithValues: nearby.compactMap { station in
                    guard let seconds = station.nearbyDurationSeconds else { return nil }
                    return (station.id, max(1, Int((seconds / 60).rounded(.up))))
                }
            )
            let missing = nearby.filter { distances[$0.id] == nil }
            if !missing.isEmpty {
                let calculated = locationService.calculateDistances(to: missing)
                for (station, distance) in calculated {
                    distances[station.id] = distance
                }
            }

            stationDistances = distances
            nearbyStations = Array(nearby.prefix(5))
            lastLocation = location
            lastUpdate = Date()
        } catch {
            // Fallback: local distance calculation from whatever stations we have
            let calculated = locationService.calculateDistances(to: nearbyStations)
            stationDistances = Dictionary(uniqueKeysWithValues: calculated.map { ($0.station.id, $0.distance) })
            lastLocation = location
            lastUpdate = Date()
        }
    }

    func suggestedTravelTimeMinutes(for stationId: String?) -> Int? {
        guard let stationId else { return nil }
        return stationSuggestedTravelTimes[stationId]
    }

    func updateDistances(for stations: [Station]) {
        let calculated = locationService.calculateDistances(to: stations)
        var updated = stationDistances
        for (station, distance) in calculated {
            updated[station.id] = distance
        }
        stationDistances = updated
    }

    func updateDistances(forAll stations: [Station]) {
        let calculated = locationService.calculateDistances(to: stations)
        stationDistances = Dictionary(uniqueKeysWithValues: calculated.map { ($0.station.id, $0.distance) })
    }
}
