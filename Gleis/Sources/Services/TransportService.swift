import Foundation

final class TransportService: TransportServiceProtocol, @unchecked Sendable {
    static let shared = TransportService()
    private static let gateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
    private static let gateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HHmmss"
        return formatter
    }()
    private let apiClient: OebbAPIClient
    private let storage: StorageServiceProtocol
    private let stationCacheLock = NSLock()
    private let connectionPrefetchLock = NSLock()
    private var browseStationsCache: [Station]?
    private var browseStationsFetchTask: Task<[Station], Error>?
    private var resolvedStationRefsByStationId: [String: OebbStationRef] = [:]
    private var prewarmedPagesByRoute: [String: PrewarmEntry] = [:]

    init(apiClient: OebbAPIClient = .shared, storage: StorageServiceProtocol = LocalStorageService.shared) {
        self.apiClient = apiClient
        self.storage = storage
    }

    func fetchConnections(from: Station, to: Station) async throws -> [TrainConnection] {
        try await fetchConnections(
            from: from,
            to: to,
            departureTime: Date(),
            count: FetchLimits.connectionBatchSize
        )
    }

    func fetchConnections(
        from: Station, to: Station, departureTime: Date, count: Int
    ) async throws -> [TrainConnection] {
        try await fetchConnectionsFromAPI(
            from: from,
            to: to,
            departureTime: departureTime,
            count: count
        )
    }

    func fetchConnectionsPage(
        from: Station,
        to: Station,
        seedDateTime: Date,
        pageSize: Int,
        cursor: String?
    ) async throws -> ConnectionPage {
        return try await fetchConnectionsPageFromAPI(
            from: from,
            to: to,
            seedDateTime: seedDateTime,
            pageSize: max(1, pageSize),
            cursor: cursor
        )
    }

    // MARK: - Launch Prewarm

    private struct PrewarmEntry {
        let task: Task<PrewarmedConnectionsPage, Error>
        let startedAt: Date
    }

    /// How long a prewarmed first page stays claimable. Past this the departures it
    /// holds are no longer current enough to present as live.
    private static let prewarmFreshnessWindow: TimeInterval = 90

    func prewarmConnections(from: Station, to: Station) {
        guard from.id != to.id else { return }
        let key = routeKey(from: from, to: to)

        let startedAt = Date()
        connectionPrefetchLock.lock()
        // Drop entries nobody claimed. A route the user navigated away from leaves its
        // task running and its entry in the dictionary otherwise, one per distinct
        // route for the life of the process.
        for (staleKey, entry) in prewarmedPagesByRoute
            where startedAt.timeIntervalSince(entry.startedAt) > Self.prewarmFreshnessWindow
        {
            entry.task.cancel()
            prewarmedPagesByRoute.removeValue(forKey: staleKey)
        }
        if let existing = prewarmedPagesByRoute[key],
           startedAt.timeIntervalSince(existing.startedAt) <= Self.prewarmFreshnessWindow
        {
            connectionPrefetchLock.unlock()
            return
        }
        let task = Task<PrewarmedConnectionsPage, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let page = try await fetchConnectionsPageFromAPI(
                from: from,
                to: to,
                seedDateTime: startedAt,
                pageSize: FetchLimits.connectionBatchSize,
                cursor: nil
            )
            return PrewarmedConnectionsPage(page: page, seedDateTime: startedAt)
        }
        prewarmedPagesByRoute[key] = PrewarmEntry(task: task, startedAt: startedAt)
        connectionPrefetchLock.unlock()
    }

    /// Lock use stays in a synchronous method; `NSLock` must not be held across an await.
    private func takePrewarmEntry(forKey key: String) -> PrewarmEntry? {
        connectionPrefetchLock.lock()
        defer { connectionPrefetchLock.unlock() }
        return prewarmedPagesByRoute.removeValue(forKey: key)
    }

    func claimPrewarmedConnections(from: Station, to: Station) async throws -> PrewarmedConnectionsPage? {
        let key = routeKey(from: from, to: to)
        guard let entry = takePrewarmEntry(forKey: key) else { return nil }
        // Age is measured from when the request started, not from when it finished, so a
        // slow response cannot be presented as fresher than the timetable it describes.
        guard Date().timeIntervalSince(entry.startedAt) <= Self.prewarmFreshnessWindow else {
            entry.task.cancel()
            return nil
        }

        do {
            let result = try await entry.task.value
            // Re-check after awaiting: the request itself can take most of the window.
            guard Date().timeIntervalSince(entry.startedAt) <= Self.prewarmFreshnessWindow else { return nil }
            return result
        } catch {
            // A failed prewarm is not an error for the caller; it just means there is
            // nothing to inherit and the normal fetch should run.
            if isCancellation(error) { return nil }
            return nil
        }
    }

    /// Pages the provider until the requested span of timetable is actually in hand.
    ///
    /// A single TripSearch returns six or seven trips no matter what `numF` says, so
    /// one request covers minutes on a dense route and a few hours on a sparse one.
    /// Callers that need "this morning" or "a day of departures" cannot express that
    /// as a page size; they express it as coverage and this walks the cursor for them.
    func fetchConnectionsCovering(
        from: Station,
        to: Station,
        seedDateTime: Date,
        coverage: ConnectionCoverage,
        onPage: (@Sendable ([TrainConnection]) async -> Void)? = nil
    ) async throws -> ConnectionCoverageResult {
        var collected: [TrainConnection] = []
        var seenIds = Set<String>()
        var cursor: String?
        let deadline = Date().addingTimeInterval(coverage.budget)

        func isWanted(_ connection: TrainConnection) -> Bool {
            if let notBefore = coverage.notBefore, connection.departureTime < notBefore { return false }
            if let notAfter = coverage.notAfter, connection.departureTime >= notAfter { return false }
            return true
        }

        func hasReachedCoverage() -> Bool {
            if collected.count < coverage.minimumCount { return false }
            guard let through = coverage.throughDeparture else { return true }
            return collected.contains { $0.departureTime >= through }
        }

        for _ in 0 ..< FetchLimits.maxCoveragePages {
            try Task.checkCancellation()
            let page = try await fetchConnectionsPageFromAPI(
                from: from,
                to: to,
                seedDateTime: seedDateTime,
                pageSize: FetchLimits.connectionBatchSize,
                cursor: cursor
            )

            var pageAdditions: [TrainConnection] = []
            for connection in page.connections where isWanted(connection) {
                if seenIds.insert(connection.id).inserted {
                    collected.append(connection)
                    pageAdditions.append(connection)
                }
            }

            // Hand each page over as it lands. Pages get slower the deeper they go —
            // measured 3.0s, 3.9s, 8.9s, 8.2s on one route — so waiting for the whole
            // run before showing anything is the difference between a 3s and a 24s
            // first paint.
            if !pageAdditions.isEmpty, let onPage {
                await onPage(pageAdditions.sorted { $0.departureTime < $1.departureTime })
            }

            // A cursor that is absent or unchanged means the provider has nothing
            // further to offer; stop rather than refetching the same page.
            guard let nextCursor = page.forwardCursor, nextCursor != cursor else {
                cursor = nil
                break
            }
            cursor = nextCursor

            if hasReachedCoverage() { break }
            // Stop before starting a page that cannot finish inside the budget.
            if Date() >= deadline { break }
        }

        collected.sort { $0.departureTime < $1.departureTime }
        return ConnectionCoverageResult(
            connections: collected,
            forwardCursor: cursor,
            seedDateTime: seedDateTime
        )
    }

    private func fetchConnectionsFromAPI(
        from: Station,
        to: Station,
        departureTime: Date,
        count: Int
    ) async throws -> [TrainConnection] {
        let page = try await fetchConnectionsPageFromAPI(
            from: from,
            to: to,
            seedDateTime: departureTime,
            pageSize: count,
            cursor: nil
        )
        return page.connections
    }

    private func fetchConnectionsPageFromAPI(
        from: Station,
        to: Station,
        seedDateTime: Date,
        pageSize: Int,
        cursor: String?
    ) async throws -> ConnectionPage {
        do {
            async let resolvedFromTask = resolveStation(from)
            async let resolvedToTask = resolveStation(to)
            let (resolvedFrom, resolvedTo) = try await (resolvedFromTask, resolvedToTask)
            let page = try await apiClient.fetchConnectionsPage(
                from: resolvedFrom.ref,
                to: resolvedTo.ref,
                pageSize: pageSize,
                seedDateTime: seedDateTime,
                cursor: cursor
            )
            let connections = page.connections.map {
                ConnectionMapper.map($0, from: resolvedFrom.station, to: resolvedTo.station)
            }
            return ConnectionPage(
                connections: connections,
                forwardCursor: page.forwardCursor,
                backwardCursor: page.backwardCursor,
                requestDate: page.requestDate,
                requestTime: page.requestTime,
                pageSize: page.pageSize
            )
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

    func fetchStations() async throws -> [Station] {
        if let cached = cachedStations() { return cached }
        if let persisted = persistedStations(), !persisted.isEmpty {
            cacheStations(persisted)
            return persisted
        }
        if let fetchTask = stationFetchTask() {
            return try await fetchTask.value
        }

        let fetchTask = Task<[Station], Error> { [apiClient] in
            try await apiClient.searchStations(query: "", count: FetchLimits.stationBrowseCount).map {
                ConnectionMapper.mapStation($0)
            }
        }
        setStationFetchTask(fetchTask)

        do {
            let stations = try await fetchTask.value
            // An empty browse result is a provider hiccup; keeping it would block every later fetch.
            if !stations.isEmpty {
                cacheStations(stations)
                persistStations(stations)
            }
            setStationFetchTask(nil)
            return stations
        } catch {
            setStationFetchTask(nil)
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    func searchStations(matching query: String) async throws -> [Station] {
        do {
            return try await apiClient.searchStations(query: query, count: FetchLimits.stationSearchCount).map {
                ConnectionMapper.mapStation($0)
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

    private func resolveStation(_ station: Station) async throws -> ResolvedStation {
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
        let mapped = ConnectionMapper.mapStation(first)
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

    private func cachedStations() -> [Station]? {
        stationCacheLock.lock()
        defer { stationCacheLock.unlock() }
        return browseStationsCache
    }

    private func cacheStations(_ stations: [Station]) {
        stationCacheLock.lock()
        browseStationsCache = stations
        stationCacheLock.unlock()
    }

    private func stationFetchTask() -> Task<[Station], Error>? {
        stationCacheLock.lock()
        defer { stationCacheLock.unlock() }
        return browseStationsFetchTask
    }

    private func setStationFetchTask(_ task: Task<[Station], Error>?) {
        stationCacheLock.lock()
        browseStationsFetchTask = task
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

    // Stations are stored in a dictionary under the old transport-type key so caches already on disk still load.
    private static let persistedStationsKey = "Train"

    private func persistedStations() -> [Station]? {
        guard
            let stored: [String: [Station]] = try? storage.load(forKey: StorageKey.cachedStations.rawValue)
        else { return nil }
        return stored[Self.persistedStationsKey]
    }

    private func persistStations(_ stations: [Station]) {
        var stored: [String: [Station]] = (try? storage.load(forKey: StorageKey.cachedStations.rawValue)) ?? [:]
        stored[Self.persistedStationsKey] = stations
        try? storage.save(stored, forKey: StorageKey.cachedStations.rawValue)
    }

    private func routeKey(from: Station, to: Station) -> String {
        "\(from.id)|\(to.id)"
    }

}
