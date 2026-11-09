import Foundation
import OSLog

/// Which step of the seat lookup failed, kept so the seat sheet can show it in debug builds.
struct SeatMapLoadError: LocalizedError {
    let step: String
    let underlying: Error
    var errorDescription: String? { "\(step): \(String(describing: underlying))" }
}

final class TransportService: TransportServiceProtocol, @unchecked Sendable {
    static let shared = TransportService()
    private static let tripLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.veno.gleis", category: "Trips")
    private static let seatLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.veno.gleis", category: "Seats")
    private let apiClient: OebbAPIClient
    private let storage: StorageServiceProtocol
    private let stationCacheLock = NSLock()
    private let connectionPrefetchLock = NSLock()
    private var browseStationsCache: [Station]?
    private var browseStationsFetchTask: Task<[Station], Error>?
    private var resolvedStationRefsByStationId: [String: OebbStationRef] = [:]
    private var resolvedStationRefsByName: [String: OebbStationRef] = [:]
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
            // Ids now name the trip, so a repeated id here is the same trip listed twice and safe to drop.
            var seenIds = Set<String>()
            let mapped = page.connections.map {
                ConnectionMapper.map($0, from: resolvedFrom.station, to: resolvedTo.station)
            }
            let connections = mapped.filter { seenIds.insert($0.id).inserted }
            #if DEBUG
            Self.tripLogger.info(
                "Trip page \(resolvedFrom.station.name, privacy: .public) to \(resolvedTo.station.name, privacy: .public): ÖBB sent \(page.connections.count), kept \(connections.count): \(connections.map(ConnectionIdentity.debugDescription).joined(separator: " | "), privacy: .public)"
            )
            #endif
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
            let detail = try await apiClient.fetchConnectionDetails(
                connectionId: connection.providerConnectionId ?? connection.id
            )
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
            // ÖBB can answer "Graz Hbf (U)" or "Graz Hauptbahnhof" with nothing, so shorter forms of the name follow.
            for searchQuery in Self.stationSearchQueries(for: query) {
                let stations = try await apiClient.searchStations(
                    query: searchQuery, count: FetchLimits.stationSearchCount
                ).map(ConnectionMapper.mapStation)
                if !stations.isEmpty { return stations }
            }
            return []
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw mapError(error)
        }
    }

    // MARK: - Seat Maps

    /// How long before the scheduled departure the shop search starts.
    private static let seatMapSearchLeadTime: TimeInterval = 60
    /// How far a shop section's departure may be from the app's and still be the same train.
    private static let seatMapMatchTolerance: TimeInterval = 180
    /// Marks a station id made up from a city name, so it never parses as a station number.
    private static let cityStationIdPrefix = "city:"
    /// Shop timetable entries asked for when looking the trip up, starting just before it leaves.
    private static let seatMapShopSearchCount = 5
    private static let shopJourneySectionType = "journey"
    private static let preferredReservationClasses = ["1", "2"]
    /// Session lifetime the seat lookup needs, so its chain of shop calls stays on one ÖBB session.
    private static let seatMapSessionMinimumLifetime: TimeInterval = 300
    // Longer than any ÖBB session, so asking for it always starts a new one.
    private static let forcedSessionRenewalWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Seat availability per leg, read from the ÖBB shop: timetable, offers, reservation details, then seat maps.
    func fetchSeatMaps(for connection: TrainConnection) async throws -> [LegSeatMap] {
        do {
            return try await fetchSeatMapsOnce(for: connection)
        } catch let error as SeatMapLoadError
            where Self.isSignInFailure(error.underlying) && !GleisError.from(error.underlying).isBusyLike
        {
            // The first lookup after a while can be refused by ÖBB's sign-in; a fresh session and one
            // full rerun is what fixed it by hand, so do that once instead of making the user retry.
            Self.seatLogger.info("Seat lookup retries once with a new ÖBB session after: \(error.step, privacy: .public)")
            try await apiClient.ensureSessionValid(forAtLeast: Self.forcedSessionRenewalWindow)
            return try await fetchSeatMapsOnce(for: connection)
        }
    }

    private static func stopsSeatRouteSearch(_ error: GleisError) -> Bool {
        switch error {
        case .timeout, .offline, .networkError: return true
        default: return error.isBusyLike
        }
    }

    private static func isSignInFailure(_ error: Error) -> Bool {
        guard case let GleisError.apiError(message) = error else { return false }
        return message.hasPrefix("Auth failed") || message.hasPrefix("Session expired")
    }

    private func fetchSeatMapsOnce(for connection: TrainConnection) async throws -> [LegSeatMap] {
        var step = "session"
        do {
            try await apiClient.ensureSessionValid(forAtLeast: Self.seatMapSessionMinimumLifetime)
            step = "shop timetable"
            // A fresh passenger id per lookup, as the shop web app creates one per search.
            let passenger = OebbTimetableRequest.Passenger.adult(id: Int(Date().timeIntervalSince1970))
            let (shopConnection, searchDate) = try await findShopConnection(for: connection, passenger: passenger)
            step = "prices"
            try await apiClient.priceConnection(connectionId: shopConnection.id)
            step = "offers"
            let offers = try await apiClient.fetchOffers(
                connectionId: shopConnection.id, passenger: passenger, searchDate: searchDate
            )
            guard !offers.offerError, let offerSections = offers.offerSections, !offerSections.isEmpty else {
                let trip = "\(connection.lineNumber) from \(connection.departureStation.name)"
                throw GleisError.apiError("ÖBB could not load the seat offers for \(trip). Please try again.")
            }
            let selections = offerSections.compactMap(Self.reservationSelection(for:))
            guard !selections.isEmpty else { return Self.unreservableLegs(of: connection) }

            step = "reservation details"
            let details = try await apiClient.fetchReservationDetails(
                connectionId: shopConnection.id, selections: selections
            )
            let journeySections = details.sections.filter {
                ($0.type ?? Self.shopJourneySectionType) == Self.shopJourneySectionType
            }
            guard !journeySections.isEmpty else {
                let trip = "\(connection.lineNumber) from \(connection.departureStation.name)"
                throw GleisError.apiError("ÖBB did not send seat information for \(trip).")
            }

            var usedLegIndices = Set<Int>()
            var legSeatMaps: [LegSeatMap] = []
            for (position, section) in journeySections.enumerated() {
                let lineName = Self.lineName(of: section)
                let legIndex = Self.legIndex(matching: lineName, in: connection, excluding: usedLegIndices)
                    ?? connection.legs.count + position
                usedLegIndices.insert(legIndex)
                step = "seat map for \(lineName)"
                legSeatMaps.append(try await legSeatMap(for: section, lineName: lineName, legIndex: legIndex))
            }
            return legSeatMaps
        } catch {
            if isCancellation(error) { throw CancellationError() }
            Self.seatLogger.error(
                "Seat lookup for \(connection.lineNumber, privacy: .public) failed at \(step, privacy: .public): \(String(describing: error), privacy: .private)"
            )
            throw SeatMapLoadError(step: step, underlying: error)
        }
    }

    /// The same trip in the shop timetable, which is the only source of the id the offer endpoints accept.
    private func findShopConnection(
        for connection: TrainConnection, passenger: OebbTimetableRequest.Passenger
    ) async throws -> (connection: OebbConnection, searchDate: Date) {
        let trainLegs = connection.legs.filter { !$0.isWalking }
        let firstTrainLeg = trainLegs.first
        let trainDeparture = firstTrainLeg?.departureTime ?? connection.departureTime
        let delayMinutes = firstTrainLeg?.departureDelayMinutes ?? connection.delay
        let scheduledDeparture = trainDeparture.addingTimeInterval(-TimeInterval(delayMinutes * 60))
        let searchDate = scheduledDeparture.addingTimeInterval(-Self.seatMapSearchLeadTime)
        let lineName = Self.normalizedLineName(firstTrainLeg?.lineNumber ?? connection.lineNumber)

        var searchedRefNumbers = Set<[Int]>()
        var searchedRoutes: [String] = []
        var lastRouteFailure: GleisError?
        for route in Self.shopSearchRoutes(for: connection, trainLegs: trainLegs) {
            do {
                async let resolvedFromTask = resolveStation(route.from)
                async let resolvedToTask = resolveStation(route.to)
                let (resolvedFrom, resolvedTo) = try await (resolvedFromTask, resolvedToTask)
                guard searchedRefNumbers.insert([resolvedFrom.ref.number, resolvedTo.ref.number]).inserted else {
                    continue
                }
                searchedRoutes.append("\(resolvedFrom.ref.name) (\(resolvedFrom.ref.number)) to \(resolvedTo.ref.name)")
                Self.seatLogger.debug(
                    "Seat lookup searches the shop from \(resolvedFrom.ref.name, privacy: .public) (\(resolvedFrom.ref.number)) to \(resolvedTo.ref.name, privacy: .public)"
                )
                let shopConnections = try await apiClient.searchShopConnectionsForSeats(
                    from: resolvedFrom.ref, to: resolvedTo.ref, departure: searchDate,
                    count: Self.seatMapShopSearchCount, passenger: passenger
                )
                if let match = Self.shopConnection(
                    in: shopConnections, providerConnectionId: connection.providerConnectionId,
                    lineName: lineName, departures: [scheduledDeparture, trainDeparture]
                ) {
                    return (match, searchDate)
                }
            } catch GleisError.stationNotFound {
                // ÖBB answered the station search with nothing usable, so the next route may still find the train.
                searchedRoutes.append("\(route.from.name) to \(route.to.name): station not found")
            } catch {
                if isCancellation(error) { throw CancellationError() }
                let mapped = mapError(error)
                // A dead connection, a busy ÖBB or a refused sign-in fails the same way on every route; any other
                // answer is about this station pair, so the next route may still find the train.
                if Self.stopsSeatRouteSearch(mapped) || Self.isSignInFailure(error) { throw mapped }
                searchedRoutes.append("\(route.from.name) to \(route.to.name): \(String(describing: mapped))")
                lastRouteFailure = mapped
            }
        }
        if searchedRefNumbers.isEmpty {
            // Only a plain "no such station" answer should read as one; any other failure keeps its own text.
            if let otherFailure = lastRouteFailure { throw otherFailure }
            throw GleisError.stationNotFound
        }
        let trip = "\(connection.lineNumber) leaving \(connection.departureStation.name)"
        throw GleisError.apiError(
            "The ÖBB shop does not list \(trip), so its seats cannot be shown. Searched: \(searchedRoutes.joined(separator: "; "))."
        )
    }

    private struct ShopSearchRoute {
        let from: Station
        let to: Station
    }

    /// The train legs' own stations first: a trip from a meta stop such as "Wien Hbf (U)" starts with a walk and
    /// ÖBB returns no seat offers for it. Then the stations the user picked, then the city stop for each name.
    private static func shopSearchRoutes(
        for connection: TrainConnection, trainLegs: [ConnectionLeg]
    ) -> [ShopSearchRoute] {
        let trainRoute = ShopSearchRoute(
            from: trainLegs.first?.from ?? connection.departureStation,
            to: trainLegs.last?.to ?? connection.arrivalStation
        )
        let pickedRoute = ShopSearchRoute(from: connection.departureStation, to: connection.arrivalStation)
        let cityRoute = { (route: ShopSearchRoute) in
            ShopSearchRoute(from: cityStation(of: route.from), to: cityStation(of: route.to))
        }
        return [trainRoute, pickedRoute, cityRoute(trainRoute), cityRoute(pickedRoute)]
    }

    /// A station known only by its city name, which the name search resolves to the city's meta stop.
    private static func cityStation(of station: Station) -> Station {
        let city = Station.cityName(station.name)
        return Station(id: cityStationIdPrefix + Station.comparableName(city), name: city, coordinate: nil)
    }

    /// A shop trip with a train section on the same line leaving at one of `departures`, preferring the app's
    /// id. ÖBB shares one id across feeder variants, so the id alone never picks the trip.
    private static func shopConnection(
        in shopConnections: [OebbConnection], providerConnectionId: String?, lineName: String, departures: [Date]
    ) -> OebbConnection? {
        let sameTrain = shopConnections.filter { shop in
            (shop.sections ?? []).contains { section in
                guard let category = section.category, !ConnectionMapper.isWalkingCategory(category),
                      normalizedLineName(ConnectionMapper.lineInfo(for: category).number) == lineName,
                      let departure = ConnectionMapper.parseDate(section.from.departure)
                else { return false }
                return departures.contains { abs(departure.timeIntervalSince($0)) <= seatMapMatchTolerance }
            }
        }
        return sameTrain.first { $0.id == providerConnectionId } ?? sameTrain.first
    }

    private func legSeatMap(
        for section: OebbReservationDetailsSection, lineName: String, legIndex: Int
    ) async throws -> LegSeatMap {
        let fromName = section.fromName ?? ""
        let toName = section.toName ?? ""
        guard let graphical = section.graphical, graphical.isAvailable == true, let ride = graphical.ride else {
            return LegSeatMap(
                id: legIndex, lineName: lineName, fromName: fromName, toName: toName, content: .reservableWithoutMap
            )
        }
        let response = try await apiClient.fetchGraphicalReservation(ride: ride)
        guard !response.coaches.isEmpty else {
            throw GleisError.apiError("ÖBB sent an empty seat map for \(lineName) from \(fromName).")
        }
        let seatMap = SeatMap.from(
            graphicalReservation: response, rideName: lineName, fromName: fromName, toName: toName
        )
        return LegSeatMap(id: legIndex, lineName: lineName, fromName: fromName, toName: toName, content: .map(seatMap))
    }

    /// Picks the first-class reservation-only offer, else second class, else whatever class is offered.
    private static func reservationSelection(for section: OebbOfferSection) -> OebbReservationOfferSelection? {
        guard let sectionId = section.id else { return nil }
        let offers = section.reservationOffers.filter { $0.id != nil && $0.travelClass != nil }
        let preferred = preferredReservationClasses.lazy.compactMap { travelClass in
            offers.first { $0.travelClass == travelClass }
        }.first
        guard let offer = preferred ?? offers.first, let offerId = offer.id, let travelClass = offer.travelClass else {
            return nil
        }
        return OebbReservationOfferSelection(
            reservationOnly: .init(isSelected: true, offerId: offerId, travelClass: travelClass),
            id: sectionId
        )
    }

    private static func unreservableLegs(of connection: TrainConnection) -> [LegSeatMap] {
        connection.legs.enumerated().filter { !$0.element.isWalking }.map { index, leg in
            LegSeatMap(
                id: index, lineName: leg.lineNumber, fromName: leg.from.name, toName: leg.to.name,
                content: .notReservable
            )
        }
    }

    private static func lineName(of section: OebbReservationDetailsSection) -> String {
        [section.rideShortName, section.rideNumber].compactMap { $0 }.joined(separator: " ")
    }

    private static func legIndex(
        matching lineName: String, in connection: TrainConnection, excluding used: Set<Int>
    ) -> Int? {
        let wanted = normalizedLineName(lineName)
        guard !wanted.isEmpty else { return nil }
        return connection.legs.indices.first { index in
            !used.contains(index) && !connection.legs[index].isWalking
                && normalizedLineName(connection.legs[index].lineNumber) == wanted
        }
    }

    private static func normalizedLineName(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace }
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
        let knownStations = cachedStations() ?? persistedStations() ?? []
        if let known = knownStations.first(where: { $0.id == station.id }), let ref = makeStationRef(for: known) {
            cacheResolvedStationRef(ref, forStationId: station.id)
            return ResolvedStation(station: known, ref: ref)
        }
        let nameKey = Station.comparableName(station.name)
        if let cachedRef = cachedResolvedStationRef(forStationName: nameKey) {
            cacheResolvedStationRef(cachedRef, forStationId: station.id)
            return ResolvedStation(station: station, ref: cachedRef)
        }
        // Leg names carry platform suffixes such as "Wien Hbf (Bahnsteige 3-12)" that the name search may not match.
        let number = stationNumber(for: station)
        var nearestGuess: ResolvedStation?
        var foundOwnEntry = false
        for query in Self.stationSearchQueries(for: station.name) {
            let candidates = try await apiClient.searchStations(
                query: query,
                count: FetchLimits.stationResolveCandidateCount
            ).map(ConnectionMapper.mapStation)
            let located = candidates.compactMap { candidate in
                makeStationRef(for: candidate).map { ResolvedStation(station: candidate, ref: $0) }
            }
            if let resolved = matchingCandidate(for: station, among: located) {
                cacheResolvedStationRef(resolved.ref, forStationId: station.id)
                cacheResolvedStationRef(resolved.ref, forStationId: resolved.station.id)
                cacheResolvedStationRef(resolved.ref, forStationName: nameKey)
                return resolved
            }
            foundOwnEntry = foundOwnEntry || candidates.contains { number != nil && stationNumber(for: $0) == number }
            nearestGuess = nearestGuess ?? located.first
        }
        // The station's own entry without coordinates means any other hit would be a different station.
        // A guess is not cached, so the next lookup searches again rather than reusing a possibly wrong station.
        if !foundOwnEntry, let nearestGuess {
            Self.seatLogger.notice(
                "No exact ÖBB station for \(station.name, privacy: .public) (\(station.id, privacy: .public)), using \(nearestGuess.ref.name, privacy: .public) (\(nearestGuess.ref.number))"
            )
            return nearestGuess
        }
        Self.seatLogger.error("No ÖBB station found for \(station.name, privacy: .public) (\(station.id, privacy: .public))")
        throw GleisError.stationNotFound
    }

    /// The candidate with the station's number, else the same name, else the same name without brackets.
    private func matchingCandidate(for station: Station, among located: [ResolvedStation]) -> ResolvedStation? {
        let number = stationNumber(for: station)
        let name = Station.comparableName(station.name)
        let bareName = Station.comparableName(Station.nameWithoutBrackets(station.name))
        return located.first { number != nil && $0.ref.number == number }
            ?? located.first { Station.comparableName($0.station.name) == name }
            ?? located.first { Station.comparableName(Station.nameWithoutBrackets($0.station.name)) == bareName }
    }

    /// The name as given, without a trailing bracketed part, then the city alone: "Graz Hbf (U)", "Graz Hbf", "Graz".
    private static func stationSearchQueries(for name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return [trimmed, Station.nameWithoutBrackets(trimmed), Station.cityName(trimmed)].filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
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

    private func cachedResolvedStationRef(forStationName comparableName: String) -> OebbStationRef? {
        stationCacheLock.lock()
        defer { stationCacheLock.unlock() }
        return resolvedStationRefsByName[comparableName]
    }

    private func cacheResolvedStationRef(_ ref: OebbStationRef, forStationName comparableName: String) {
        stationCacheLock.lock()
        resolvedStationRefsByName[comparableName] = ref
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
