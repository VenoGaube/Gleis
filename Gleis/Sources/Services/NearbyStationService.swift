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
    private let walkingSpeedMetersPerSecond: Double = 1.4

    init(
        transportService: TransportServiceProtocol = TransportService.shared,
        locationService: LocationService = LocationService.shared
    ) {
        self.transportService = transportService
        self.locationService = locationService
    }

    func refreshIfNeeded(
        transportType: TransportType,
        knownStations: [Station] = [],
        isBackground: Bool = false
    ) async {
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

            // Include all known stations so UI can show distance for more than nearby-only rows.
            let expandedStations = mergeStations(primary: knownStations, secondary: nearby)

            // Prefer local geo-distance for consistency and precision when coordinates are available.
            let calculated = locationService.calculateDistances(to: expandedStations)
            var distances = Dictionary(uniqueKeysWithValues: calculated.map { ($0.station.id, $0.distance) })

            // Fall back to API-provided distance when local coordinates are missing.
            for station in nearby where distances[station.id] == nil {
                if let apiDistance = station.nearbyDistanceMeters {
                    distances[station.id] = apiDistance
                }
            }

            stationDistances = distances
            stationSuggestedTravelTimes = buildSuggestedTravelTimes(distances: distances, fallbackNearby: nearby)
            nearbyStations = Array(nearby.prefix(5))
            lastLocation = location
            lastUpdate = Date()
        } catch {
            // Fallback: local distance calculation from all known stations if available.
            let fallbackStations = mergeStations(primary: knownStations, secondary: nearbyStations)
            let calculated = locationService.calculateDistances(to: fallbackStations)
            stationDistances = Dictionary(uniqueKeysWithValues: calculated.map { ($0.station.id, $0.distance) })
            stationSuggestedTravelTimes = Dictionary(
                uniqueKeysWithValues: calculated.map { ($0.station.id, suggestedMinutes(fromDistanceMeters: $0.distance)) }
            )
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
        var suggestions = stationSuggestedTravelTimes
        for (station, distance) in calculated {
            updated[station.id] = distance
            suggestions[station.id] = suggestedMinutes(fromDistanceMeters: distance)
        }
        stationDistances = updated
        stationSuggestedTravelTimes = suggestions
    }

    private func suggestedMinutes(fromDistanceMeters distance: CLLocationDistance) -> Int {
        max(1, Int((distance / walkingSpeedMetersPerSecond / 60).rounded(.up)))
    }

    private func buildSuggestedTravelTimes(
        distances: [String: Double],
        fallbackNearby: [Station]
    ) -> [String: Int] {
        var suggestions = Dictionary(
            uniqueKeysWithValues: distances.map { (stationId: String, distance: Double) in
                (stationId, suggestedMinutes(fromDistanceMeters: distance))
            }
        )

        // If a station lacks local distance data, fall back to API-provided duration.
        for station in fallbackNearby where suggestions[station.id] == nil {
            guard let seconds = station.nearbyDurationSeconds else { continue }
            suggestions[station.id] = max(1, Int((seconds / 60).rounded(.up)))
        }

        return suggestions
    }

    private func mergeStations(primary: [Station], secondary: [Station]) -> [Station] {
        var ids = Set<String>()
        var merged: [Station] = []

        for station in primary where ids.insert(station.id).inserted {
            merged.append(station)
        }

        for station in secondary where ids.insert(station.id).inserted {
            merged.append(station)
        }

        return merged
    }
}
