import Foundation

final class TransportService: TransportServiceProtocol, @unchecked Sendable {
    static let shared = TransportService()
    private let apiClient: OebbAPIClient

    init(apiClient: OebbAPIClient = .shared) {
        self.apiClient = apiClient
    }

    func fetchConnections(from: Station, to: Station, transportType: TransportType) async throws -> [TrainConnection] {
        try await fetchConnections(from: from, to: to, transportType: transportType, departureTime: Date(), count: 15)
    }

    func fetchConnectionsFromMidnight(
        from: Station, to: Station, transportType: TransportType
    ) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from, to: to, transportType: transportType, departureTime: Calendar.current.startOfDay(for: Date()),
            count: 6
        )
    }

    func fetchMoreConnections(
        from: Station, to: Station, transportType: TransportType, after lastDeparture: Date
    ) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from, to: to, transportType: transportType, departureTime: lastDeparture.addingTimeInterval(60),
            count: 6
        )
    }

    func fetchConnections(
        from: Station, to: Station, transportType: TransportType, departureTime: Date, count: Int
    ) async throws -> [TrainConnection] {
        do {
            let resolvedFrom = try await resolveStation(from, transportType: transportType)
            let resolvedTo = try await resolveStation(to, transportType: transportType)
            let response = try await apiClient.fetchTimetable(
                from: resolvedFrom.ref, to: resolvedTo.ref, count: count, departure: departureTime
            )
            let connections = response.connections.map {
                ConnectionMapper.map(
                    $0, from: resolvedFrom.station, to: resolvedTo.station, transportType: transportType
                )
            }
            return connections
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func fetchStations(for transportType: TransportType) async throws -> [Station] {
        do {
            return try await apiClient.searchStations(query: "", count: 25).map {
                ConnectionMapper.mapStation($0, transportType: transportType)
            }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func searchStations(matching query: String, transportType: TransportType) async throws -> [Station] {
        do {
            return try await apiClient.searchStations(query: query, count: 25).map {
                ConnectionMapper.mapStation($0, transportType: transportType)
            }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func searchStationsNearby(
        latitude: Double, longitude: Double, transportType: TransportType
    ) async throws -> [Station] {
        do {
            let nearby = try await apiClient.searchStationsNearbyWithDistance(
                latitude: latitude, longitude: longitude, count: 15
            )
            let mapped = nearby.map { location in
                let coordinate: Station.Coordinate? =
                    if let lat = location.latitude, let lon = location.longitude, lat != 0, lon != 0 {
                        Station.Coordinate(latitude: Double(lat) / 1_000_000, longitude: Double(lon) / 1_000_000)
                    } else {
                        nil
                    }

                return Station(
                    id: location.id, name: location.name, coordinate: coordinate, transportTypes: [transportType],
                    lines: [], countryCode: location.countryCode,
                    nearbyDistanceMeters: location.distanceMeters.map(Double.init),
                    nearbyDurationSeconds: location.durationSeconds.map(Double.init)
                )
            }
            if !mapped.isEmpty { return mapped }

            return try await apiClient.searchStationsNearby(latitude: latitude, longitude: longitude, count: 15).map {
                ConnectionMapper.mapStation($0, transportType: transportType)
            }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    // MARK: - Private

    private struct ResolvedStation {
        let station: Station
        let ref: OebbStationRef
    }

    private func resolveStation(_ station: Station, transportType: TransportType) async throws -> ResolvedStation {
        if let ref = makeStationRef(for: station) { return ResolvedStation(station: station, ref: ref) }
        let candidates = try await apiClient.searchStations(query: station.name, count: 5)
        guard let first = candidates.first else { throw GleisError.stationNotFound }
        let mapped = ConnectionMapper.mapStation(first, transportType: transportType)
        guard let ref = makeStationRef(for: mapped) else { throw GleisError.stationNotFound }
        return ResolvedStation(station: mapped, ref: ref)
    }

    private func makeStationRef(for station: Station) -> OebbStationRef? {
        guard let number = Int(station.id), let coordinate = station.coordinate else { return nil }
        return OebbStationRef(
            number: number, latitude: Int((coordinate.latitude * 1_000_000).rounded()),
            longitude: Int((coordinate.longitude * 1_000_000).rounded()), name: station.name
        )
    }

    private func mapError(_ error: Error) -> GleisError {
        if let e = error as? GleisError { return e }
        if let e = error as? URLError { return .networkError(e.localizedDescription) }
        return .apiError(error.localizedDescription)
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
