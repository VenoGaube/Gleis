import Foundation

final class TransportService: TransportServiceProtocol, @unchecked Sendable {
    static let shared = TransportService()
    private let apiClient: OebbAPIClient
    private let storage: StorageServiceProtocol
    private let stationCacheLock = NSLock()
    private let connectionPrefetchLock = NSLock()
    private var cachedStationsByTransport: [String: [Station]] = [:]
    private var stationFetchTasksByTransport: [String: Task<[Station], Error>] = [:]
    private var resolvedStationRefsByStationId: [String: OebbStationRef] = [:]
    private var prefetchedCurrentConnectionsByRoute: [String: [TrainConnection]] = [:]
    private var prefetchedMidnightConnectionsByRoute: [String: [TrainConnection]] = [:]

    init(apiClient: OebbAPIClient = .shared, storage: StorageServiceProtocol = LocalStorageService.shared) {
        self.apiClient = apiClient
        self.storage = storage
    }

    func fetchConnections(from: Station, to: Station, transportType: TransportType) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from,
            to: to,
            transportType: transportType,
            departureTime: Date(),
            count: FetchLimits.connectionBatchSize
        )
    }

    func fetchConnectionsFromMidnight(
        from: Station, to: Station, transportType: TransportType
    ) async throws -> [TrainConnection] {
        if let prefetched = consumePrefetchedMidnightConnections(from: from, to: to, transportType: transportType) {
            return Array(prefetched.prefix(FetchLimits.connectionBatchSize))
        }

        return try await fetchConnections(
            from: from, to: to, transportType: transportType, departureTime: Calendar.current.startOfDay(for: Date()),
            count: FetchLimits.connectionBatchSize
        )
    }

    func fetchMoreConnections(
        from: Station, to: Station, transportType: TransportType, after lastDeparture: Date
    ) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from, to: to, transportType: transportType, departureTime: lastDeparture.addingTimeInterval(60),
            count: FetchLimits.connectionBatchSize
        )
    }

    func fetchConnections(
        from: Station, to: Station, transportType: TransportType, departureTime: Date, count: Int
    ) async throws -> [TrainConnection] {
        let prefetchedNearNow =
            isNearNow(departureTime)
                ? consumePrefetchedCurrentConnections(from: from, to: to, transportType: transportType) : nil

        do {
            return try await fetchConnections(
                from: from,
                to: to,
                transportType: transportType,
                departureTime: departureTime,
                count: count,
                includeDetailEnrichment: false
            )
        } catch {
            if isCancellation(error) { throw error }

            // Fall back to near-now prefetch only when a live request fails.
            // This keeps first paint responsive while prioritizing reliable alert data.
            if let prefetchedNearNow,
               prefetchedNearNow.allSatisfy({ $0.serviceAlerts != nil })
            {
                return Array(prefetchedNearNow.prefix(count))
            }
            throw error
        }
    }

    func fetchConnectionsWithoutDetails(
        from: Station, to: Station, transportType: TransportType, departureTime: Date, count: Int
    ) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from,
            to: to,
            transportType: transportType,
            departureTime: departureTime,
            count: count,
            includeDetailEnrichment: false
        )
    }

    func preloadCurrentConnections(
        from: Station,
        to: Station,
        transportType: TransportType,
        count: Int = FetchLimits.connectionBatchSize
    ) async {
        guard from.id != to.id else { return }
        guard
            let connections = try? await fetchConnections(
                from: from,
                to: to,
                transportType: transportType,
                departureTime: Date(),
                count: max(1, count),
                includeDetailEnrichment: false
            ),
            !connections.isEmpty
        else { return }

        storePrefetchedCurrentConnections(connections, from: from, to: to, transportType: transportType)
    }

    func preloadMidnightConnections(
        from: Station,
        to: Station,
        transportType: TransportType,
        count: Int = FetchLimits.connectionBatchSize
    ) async {
        guard from.id != to.id else { return }
        guard
            let connections = try? await fetchConnections(
                from: from,
                to: to,
                transportType: transportType,
                departureTime: Calendar.current.startOfDay(for: Date()),
                count: max(1, count),
                includeDetailEnrichment: false
            ),
            !connections.isEmpty
        else { return }

        storePrefetchedMidnightConnections(connections, from: from, to: to, transportType: transportType)
    }

    private func fetchConnections(
        from: Station,
        to: Station,
        transportType: TransportType,
        departureTime: Date,
        count: Int,
        includeDetailEnrichment: Bool
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
            guard includeDetailEnrichment else { return connections }
            return try await enrichConnectionsBestEffort(connections)
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func enrichConnectionDetails(_ connection: TrainConnection) async throws -> TrainConnection {
        do {
            let detail = try await apiClient.fetchConnectionDetails(connectionId: connection.id)
            return ConnectionMapper.enrichConnection(connection, detail: detail)
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func fetchStations(for transportType: TransportType) async throws -> [Station] {
        if let cached = cachedStations(for: transportType) { return cached }
        if let persisted = persistedStations(for: transportType) {
            cacheStations(persisted, for: transportType)
            return persisted
        }
        if let fetchTask = stationFetchTask(for: transportType) {
            return try await fetchTask.value
        }

        let fetchTask = Task<[Station], Error> { [apiClient] in
            try await apiClient.searchStations(query: "", count: FetchLimits.stationSearchCount).map {
                ConnectionMapper.mapStation($0, transportType: transportType)
            }
        }
        setStationFetchTask(fetchTask, for: transportType)

        do {
            let stations = try await fetchTask.value
            cacheStations(stations, for: transportType)
            persistStations(stations, for: transportType)
            clearStationFetchTask(for: transportType)
            return stations
        } catch {
            clearStationFetchTask(for: transportType)
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func searchStations(matching query: String, transportType: TransportType) async throws -> [Station] {
        do {
            return try await apiClient.searchStations(query: query, count: FetchLimits.stationSearchCount).map {
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
                latitude: latitude, longitude: longitude, count: FetchLimits.nearbyStationSearchCount
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

            return try await apiClient.searchStationsNearby(
                latitude: latitude,
                longitude: longitude,
                count: FetchLimits.nearbyStationSearchCount
            ).map {
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
        if let cachedRef = cachedResolvedStationRef(forStationId: station.id) {
            return ResolvedStation(station: station, ref: cachedRef)
        }
        if let ref = makeStationRef(for: station) {
            cacheResolvedStationRef(ref, forStationId: station.id)
            return ResolvedStation(station: station, ref: ref)
        }
        let candidates = try await apiClient.searchStations(
            query: station.name,
            count: FetchLimits.stationResolveCandidateCount
        )
        guard let first = candidates.first else { throw GleisError.stationNotFound }
        let mapped = ConnectionMapper.mapStation(first, transportType: transportType)
        guard let ref = makeStationRef(for: mapped) else { throw GleisError.stationNotFound }
        cacheResolvedStationRef(ref, forStationId: station.id)
        cacheResolvedStationRef(ref, forStationId: mapped.id)
        return ResolvedStation(station: mapped, ref: ref)
    }

    private func makeStationRef(for station: Station) -> OebbStationRef? {
        guard let number = stationNumber(for: station), let coordinate = stationCoordinate(for: station) else {
            return nil
        }
        return OebbStationRef(
            number: number, latitude: Int((coordinate.latitude * 1_000_000).rounded()),
            longitude: Int((coordinate.longitude * 1_000_000).rounded()), name: station.name
        )
    }

    private func stationNumber(for station: Station) -> Int? {
        if let direct = Int(station.id) { return direct }
        return parseTaggedInteger(tag: "L", from: station.id)
    }

    private func stationCoordinate(for station: Station) -> Station.Coordinate? {
        if let coordinate = station.coordinate { return coordinate }
        guard
            let x = parseTaggedInteger(tag: "X", from: station.id),
            let y = parseTaggedInteger(tag: "Y", from: station.id)
        else {
            return nil
        }

        return Station.Coordinate(
            latitude: Double(y) / 1_000_000,
            longitude: Double(x) / 1_000_000
        )
    }

    private func parseTaggedInteger(tag: String, from value: String) -> Int? {
        let taggedPatterns = ["@\(tag)=", "\(tag)="]
        for pattern in taggedPatterns {
            guard let range = value.range(of: pattern) else { continue }
            let remainder = value[range.upperBound...]
            let end = remainder.firstIndex(of: "@") ?? remainder.endIndex
            let raw = String(remainder[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(raw) { return parsed }
        }
        return nil
    }

    private func mapError(_ error: Error) -> GleisError {
        GleisError.from(error)
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func cachedStations(for transportType: TransportType) -> [Station]? {
        stationCacheLock.lock()
        defer { stationCacheLock.unlock() }
        return cachedStationsByTransport[transportType.rawValue]
    }

    private func cacheStations(_ stations: [Station], for transportType: TransportType) {
        stationCacheLock.lock()
        cachedStationsByTransport[transportType.rawValue] = stations
        stationCacheLock.unlock()
    }

    private func stationFetchTask(for transportType: TransportType) -> Task<[Station], Error>? {
        stationCacheLock.lock()
        defer { stationCacheLock.unlock() }
        return stationFetchTasksByTransport[transportType.rawValue]
    }

    private func setStationFetchTask(_ task: Task<[Station], Error>, for transportType: TransportType) {
        stationCacheLock.lock()
        stationFetchTasksByTransport[transportType.rawValue] = task
        stationCacheLock.unlock()
    }

    private func clearStationFetchTask(for transportType: TransportType) {
        stationCacheLock.lock()
        stationFetchTasksByTransport.removeValue(forKey: transportType.rawValue)
        stationCacheLock.unlock()
    }

    private func cachedResolvedStationRef(forStationId stationId: String) -> OebbStationRef? {
        stationCacheLock.lock()
        defer { stationCacheLock.unlock() }
        return resolvedStationRefsByStationId[stationId]
    }

    private func cacheResolvedStationRef(_ ref: OebbStationRef, forStationId stationId: String) {
        stationCacheLock.lock()
        resolvedStationRefsByStationId[stationId] = ref
        stationCacheLock.unlock()
    }

    private func persistedStations(for transportType: TransportType) -> [Station]? {
        guard
            let stored: [String: [Station]] = try? storage.load(forKey: StorageKey.cachedStations.rawValue)
        else { return nil }
        return stored[transportType.rawValue]
    }

    private func persistStations(_ stations: [Station], for transportType: TransportType) {
        var stored: [String: [Station]] = (try? storage.load(forKey: StorageKey.cachedStations.rawValue)) ?? [:]
        stored[transportType.rawValue] = stations
        try? storage.save(stored, forKey: StorageKey.cachedStations.rawValue)
    }

    private func routeKey(for transportType: TransportType, from: Station, to: Station) -> String {
        "\(transportType.rawValue)|\(from.id)|\(to.id)"
    }

    private func isNearNow(_ departureTime: Date) -> Bool {
        abs(departureTime.timeIntervalSinceNow) <= 10 * 60
    }

    private func storePrefetchedCurrentConnections(
        _ connections: [TrainConnection],
        from: Station,
        to: Station,
        transportType: TransportType
    ) {
        let key = routeKey(for: transportType, from: from, to: to)
        connectionPrefetchLock.lock()
        prefetchedCurrentConnectionsByRoute[key] = connections
        connectionPrefetchLock.unlock()
    }

    private func consumePrefetchedCurrentConnections(
        from: Station,
        to: Station,
        transportType: TransportType
    ) -> [TrainConnection]? {
        let key = routeKey(for: transportType, from: from, to: to)
        connectionPrefetchLock.lock()
        defer { connectionPrefetchLock.unlock() }
        return prefetchedCurrentConnectionsByRoute.removeValue(forKey: key)
    }

    private func storePrefetchedMidnightConnections(
        _ connections: [TrainConnection],
        from: Station,
        to: Station,
        transportType: TransportType
    ) {
        let key = routeKey(for: transportType, from: from, to: to)
        connectionPrefetchLock.lock()
        prefetchedMidnightConnectionsByRoute[key] = connections
        connectionPrefetchLock.unlock()
    }

    private func consumePrefetchedMidnightConnections(
        from: Station,
        to: Station,
        transportType: TransportType
    ) -> [TrainConnection]? {
        let key = routeKey(for: transportType, from: from, to: to)
        connectionPrefetchLock.lock()
        defer { connectionPrefetchLock.unlock() }
        return prefetchedMidnightConnectionsByRoute.removeValue(forKey: key)
    }

    private func enrichConnectionsBestEffort(_ connections: [TrainConnection]) async throws -> [TrainConnection] {
        var enriched = connections
        let indicesNeedingEnrichment = enriched.indices.filter { needsDetailEnrichment(enriched[$0]) }
        guard !indicesNeedingEnrichment.isEmpty else { return enriched }

        typealias EnrichmentResult = (index: Int, enriched: TrainConnection?)
        let results: [EnrichmentResult] = try await withThrowingTaskGroup(of: EnrichmentResult.self) { group in
            for index in indicesNeedingEnrichment {
                let connection = enriched[index]
                group.addTask {
                    do {
                        let detail = try await self.apiClient.fetchConnectionDetails(connectionId: connection.id)
                        return (index: index, enriched: ConnectionMapper.enrichConnection(connection, detail: detail))
                    } catch {
                        if self.isCancellation(error) { throw CancellationError() }
                        // Keep base data when detail endpoint is unavailable for this item.
                        return (index: index, enriched: nil)
                    }
                }
            }

            var collected: [EnrichmentResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        for result in results {
            if let enrichedConnection = result.enriched {
                enriched[result.index] = enrichedConnection
            }
        }
        return enriched
    }

    private func needsDetailEnrichment(_ connection: TrainConnection) -> Bool {
        connection.legs.contains { leg in
            !leg.isWalking && (
                leg.stopCount == nil
                    || ((leg.stopCount ?? 0) > 0 && leg.intermediateStops.isEmpty)
            )
        }
    }
}
