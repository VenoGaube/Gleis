import Foundation

final class TransportService: TransportServiceProtocol {
    static let shared = TransportService()
    private let apiClient: OebbAPIClient
    private let szApiClient: SzAPIClient

    /// Whether to enrich OEBB data with SŽ data for Slovenian trains
    var enableSzEnrichment = true

    init(apiClient: OebbAPIClient = .shared, szApiClient: SzAPIClient = .shared) {
        self.apiClient = apiClient
        self.szApiClient = szApiClient
    }

    func fetchConnections(from: Station, to: Station, transportType: TransportType) async throws -> [TrainConnection] {
        try await fetchConnections(from: from, to: to, transportType: transportType, departureTime: Date(), count: 15)
    }

    func fetchConnectionsFromMidnight(
        from: Station,
        to: Station,
        transportType: TransportType
    ) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from,
            to: to,
            transportType: transportType,
            departureTime: Calendar.current.startOfDay(for: Date()),
            count: 6
        )
    }

    func fetchMoreConnections(
        from: Station,
        to: Station,
        transportType: TransportType,
        after lastDeparture: Date
    ) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from,
            to: to,
            transportType: transportType,
            departureTime: lastDeparture.addingTimeInterval(60),
            count: 6
        )
    }

    func fetchConnections(
        from: Station,
        to: Station,
        transportType: TransportType,
        departureTime: Date,
        count: Int
    ) async throws -> [TrainConnection] {
        do {
            let resolvedFrom = try await resolveStation(from, transportType: transportType)
            let resolvedTo = try await resolveStation(to, transportType: transportType)
            let response = try await apiClient.fetchTimetable(
                from: resolvedFrom.ref,
                to: resolvedTo.ref,
                count: count,
                departure: departureTime
            )
            var connections = response.connections.map { ConnectionMapper.map(
                $0,
                from: resolvedFrom.station,
                to: resolvedTo.station,
                transportType: transportType
            ) }

            // Enrich with SŽ data if enabled and stations are in Slovenia
            if enableSzEnrichment {
                connections = await enrichWithSzData(
                    connections,
                    from: resolvedFrom.station,
                    to: resolvedTo.station,
                    departureTime: departureTime
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
            return try await apiClient.searchStations(query: "", count: 25).map { ConnectionMapper.mapStation(
                $0,
                transportType: transportType
            ) }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func searchStations(matching query: String, transportType: TransportType) async throws -> [Station] {
        do {
            return try await apiClient.searchStations(query: query, count: 25).map { ConnectionMapper.mapStation(
                $0,
                transportType: transportType
            ) }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func fetchStationBoard(stationId: String, directionId: String? = nil) async throws -> [StationBoardEntry] {
        guard let evaId = Int(stationId) else { return [] }
        do {
            let board = try await apiClient.fetchStationBoard(
                evaId: evaId,
                directionId: directionId.flatMap { Int($0) }
            )
            return (board.journey ?? []).compactMap { ConnectionMapper.mapStationBoardEntry($0) }
        } catch {
            if isCancellation(error) { throw CancellationError() }
            return []
        }
    }

    // MARK: - Private

    private struct ResolvedStation { let station: Station; let ref: OebbStationRef }

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
            number: number,
            latitude: Int((coordinate.latitude * 1_000_000).rounded()),
            longitude: Int((coordinate.longitude * 1_000_000).rounded()),
            name: station.name
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

    // MARK: - SŽ Integration

    /// Enriches OEBB connections with data from the Slovenian Railways API
    /// Fills in missing platform and delay information where available
    private func enrichWithSzData(
        _ connections: [TrainConnection],
        from: Station,
        to: Station,
        departureTime: Date
    ) async -> [TrainConnection] {
        // Convert station IDs to SŽ format
        guard let szFromId = SzDataEnricher.szStationId(fromOebbEsn: from.id),
              let szToId = SzDataEnricher.szStationId(fromOebbEsn: to.id) else
        {
            // Not Slovenian stations, return unchanged
            return connections
        }

        do {
            // Fetch SŽ journey data
            let szConnections = try await szApiClient.searchJourneys(
                originId: szFromId,
                destinationId: szToId,
                date: departureTime
            )

            // Enrich each OEBB connection with matching SŽ data
            return connections.map { oebbConnection in
                let matchingSzConnection = SzDataEnricher.findMatchingConnection(oebbConnection, in: szConnections)
                return SzDataEnricher.enrich(oebbConnection, with: matchingSzConnection)
            }
        } catch {
            // SŽ API failure shouldn't break the main flow - return original data
            print("[SŽ Enrichment] Failed to fetch SŽ data: \(error.localizedDescription)")
            return connections
        }
    }
}
