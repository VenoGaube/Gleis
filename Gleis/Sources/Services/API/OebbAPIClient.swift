import Foundation

actor OebbAPIClient {
    static let shared = OebbAPIClient()
    private static let gateTrainTokenRegex = try? NSRegularExpression(
        pattern: "\\b([A-Z]{1,6})\\s*([0-9]{1,5})\\b"
    )

    private let baseURL = URL(string: "https://shop.oebbtickets.at")!
    private let fahrplanBaseURL = URL(string: "https://fahrplan.oebb.at")!
    private let storage: StorageServiceProtocol
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var authSession: OebbAuthSession?

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    private lazy var gateDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private lazy var gateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "HHmmss"
        return f
    }()

    init(storage: StorageServiceProtocol = LocalStorageService.shared, urlSession: URLSession = .shared) {
        self.storage = storage
        self.urlSession = urlSession
        authSession = try? storage.load(forKey: StorageKey.oebbAuthSession.rawValue)
    }

    // MARK: - Public API

    func searchStations(query: String, count: Int) async throws -> [OebbStation] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/hafas/v1/stations"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "name", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        return try await performAuthorized(url: components?.url, method: "GET", decode: [OebbStation].self)
    }

    func fetchConnectionsPage(
        from: OebbStationRef,
        to: OebbStationRef,
        pageSize: Int,
        seedDateTime: Date,
        cursor: String? = nil
    ) async throws -> OebbTimetablePage {
        let normalizedPageSize = max(1, min(pageSize, 30))
        let requestDate = gateDateFormatter.string(from: seedDateTime)
        let requestTime = gateTimeFormatter.string(from: seedDateTime)

        if let cursor {
            return try await fetchTimetableViaGateTripSearch(
                from: from,
                to: to,
                pageSize: normalizedPageSize,
                requestDate: requestDate,
                requestTime: requestTime,
                cursor: cursor
            )
        }

        do {
            let gateResponse = try await fetchTimetableViaGateTripSearch(
                from: from,
                to: to,
                pageSize: normalizedPageSize,
                requestDate: requestDate,
                requestTime: requestTime,
                cursor: nil
            )
            if !gateResponse.connections.isEmpty { return gateResponse }
        } catch {
            if isCancellation(error) { throw error }
            // Fall back to the authenticated shop endpoint if gate TripSearch fails.
        }

        return try await fetchTimetableViaShop(
            from: from,
            to: to,
            pageSize: normalizedPageSize,
            seedDateTime: seedDateTime
        )
    }

    func fetchTimetable(
        from: OebbStationRef, to: OebbStationRef, count: Int, departure: Date
    ) async throws -> OebbTimetableResponse {
        let page = try await fetchConnectionsPage(
            from: from,
            to: to,
            pageSize: count,
            seedDateTime: departure
        )
        return OebbTimetableResponse(connections: page.connections)
    }

    private func fetchTimetableViaShop(
        from: OebbStationRef, to: OebbStationRef, pageSize: Int, seedDateTime: Date
    ) async throws -> OebbTimetablePage {
        let payload = OebbTimetableRequest(
            reverse: false, datetimeDeparture: dateFormatter.string(from: seedDateTime), filter: .default,
            passengers: [.default], count: pageSize, debugFilter: .default,
            from: .init(latitude: from.latitude, longitude: from.longitude, name: from.name, number: from.number),
            to: .init(latitude: to.latitude, longitude: to.longitude, name: to.name, number: to.number), timeout: [:]
        )
        let url = baseURL.appendingPathComponent("api/hafas/v4/timetable")
        let response = try await performAuthorized(
            url: url, method: "POST", body: encoder.encode(payload), decode: OebbTimetableResponse.self
        )
        return OebbTimetablePage(
            connections: Array(response.connections.prefix(pageSize)),
            forwardCursor: nil,
            backwardCursor: nil,
            requestDate: gateDateFormatter.string(from: seedDateTime),
            requestTime: gateTimeFormatter.string(from: seedDateTime),
            pageSize: pageSize
        )
    }

    func fetchConnectionDetails(connectionId: String) async throws -> OebbConnectionDetailResponse {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedId = connectionId.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(baseURL.absoluteString)/api/timetable/v1/connections/\(encodedId)")
        else {
            throw GleisError.networkError("Invalid connection detail URL")
        }
        return try await performAuthorized(url: url, method: "GET", decode: OebbConnectionDetailResponse.self)
    }

    private func fetchTimetableViaGateTripSearch(
        from: OebbStationRef,
        to: OebbStationRef,
        pageSize: Int,
        requestDate: String,
        requestTime: String,
        cursor: String?
    ) async throws -> OebbTimetablePage {
        var components = URLComponents(url: fahrplanBaseURL.appendingPathComponent("gate"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "rnd", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        ]
        guard let url = components?.url else { throw GleisError.networkError("Invalid gate URL") }

        let payload = OebbGateTripSearchRequest(
            id: makeGateRequestId(),
            ver: "1.88",
            lang: "deu",
            auth: .init(type: "AID", aid: "5vHavmuWPWIfetEe"),
            client: .init(id: "OEBB", type: "WEB", name: "webapp", l: "vs_webapp", v: 21901),
            formatted: false,
            ext: "OEBB.14",
            svcReqL: [
                .init(
                    meth: "TripSearch",
                    req: .init(
                        depLocL: [.init(lid: makeGateLid(for: from), name: from.name)],
                        arrLocL: [.init(lid: makeGateLid(for: to), name: to.name)],
                        minChgTime: "-1",
                        liveSearch: false,
                        maxChg: "1000",
                        outFrwd: true,
                        outTime: requestTime,
                        outDate: requestDate,
                        getPasslist: true,
                        getTariff: false,
                        getPolyline: false,
                        numF: pageSize,
                        ctxScr: cursor,
                        pt: cursor == nil ? nil : .null
                    ),
                    id: "1|0|"
                )
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let encodedPayload = try encoder.encode(payload)
        request.httpBody = encodedPayload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var rawResponseData: Data?
        let response = try await perform(
            request,
            decode: OebbGateResponse.self,
            retryAuth: false,
            retryTransient: false,
            captureRaw: { rawResponseData = $0 }
        )
        if let err = response.err, err.uppercased() != "OK" { throw GleisError.apiError("Gate error: \(err)") }

        let service = response.svcResL?.first {
            ($0.meth ?? "").localizedCaseInsensitiveCompare("TripSearch") == .orderedSame
        } ?? response.svcResL?.first
        if let err = service?.err, err.uppercased() != "OK" { throw GleisError.apiError("Gate error: \(err)") }

        let mappedConnections = mapGateTripConnections(
            service?.res,
            fallbackFrom: from,
            fallbackTo: to
        )

        let result = OebbTimetablePage(
            connections: Array(mappedConnections.prefix(pageSize)),
            forwardCursor: service?.res?.outCtxScrF,
            backwardCursor: service?.res?.outCtxScrB,
            requestDate: requestDate,
            requestTime: requestTime,
            pageSize: pageSize
        )
        if let rawResponseData {
            persistGateSnapshotArtifact(
                routeSignature: "\(from.number)-\(to.number)",
                requestData: encodedPayload,
                responseData: rawResponseData,
                extractedConnectionIDs: result.connections.map(\.id),
                forwardCursor: result.forwardCursor,
                backwardCursor: result.backwardCursor
            )
        }
        return result
    }

    private func mapGateTripConnections(
        _ payload: OebbGateServicePayload?,
        fallbackFrom: OebbStationRef,
        fallbackTo: OebbStationRef
    ) -> [OebbConnection] {
        guard let payload else { return [] }

        let fallbackLocations = payload.locL ?? []
        var locationsByIndex = Dictionary(uniqueKeysWithValues: fallbackLocations.enumerated().map { ($0.offset, $0.element) })
        for (index, location) in (payload.common?.locL ?? []).enumerated() {
            locationsByIndex[index] = location
        }
        let productsByIndex = Dictionary(
            uniqueKeysWithValues: (payload.common?.prodL ?? []).enumerated().map { ($0.offset, $0.element) }
        )
        let iconsByIndex = Dictionary(
            uniqueKeysWithValues: (payload.common?.icoL ?? []).enumerated().map { ($0.offset, $0.element) }
        )
        let himByIndex = Dictionary(
            uniqueKeysWithValues: (payload.common?.himL ?? []).enumerated().map { ($0.offset, $0.element) }
        )

        return (payload.outConL ?? []).enumerated().map { index, connection in
            let serviceDay = connection.date ?? connection.secL?.first?.jny?.date

            let mappedSections: [OebbSection] = (connection.secL ?? []).compactMap {
                mapGateTripSection(
                    $0,
                    defaultServiceDay: serviceDay,
                    locationsByIndex: locationsByIndex,
                    productsByIndex: productsByIndex,
                    iconsByIndex: iconsByIndex
                )
            }

            let fallbackFromStop = OebbConnectionStop(
                name: fallbackFrom.name,
                esn: fallbackFrom.number,
                departure: nil,
                arrival: nil
            )
            let fallbackToStop = OebbConnectionStop(
                name: fallbackTo.name,
                esn: fallbackTo.number,
                departure: nil,
                arrival: nil
            )

            let depStop = mapGateTripStop(
                connection.dep,
                serviceDay: serviceDay,
                locationsByIndex: locationsByIndex,
                fallbackName: fallbackFrom.name,
                fallbackEsn: fallbackFrom.number
            ) ?? mappedSections.first?.from ?? fallbackFromStop
            let arrStop = mapGateTripStop(
                connection.arr,
                serviceDay: serviceDay,
                locationsByIndex: locationsByIndex,
                fallbackName: fallbackTo.name,
                fallbackEsn: fallbackTo.number
            ) ?? mappedSections.last?.to ?? fallbackToStop

            let durationMillis = gateDurationMillis(connection.durS)
                ?? gateDurationFromStops(departure: depStop.departure, arrival: arrStop.arrival)

            let normalizedId = gateNormalizedString(connection.cksum)
                ?? gateNormalizedString(connection.cid)
                ?? "gate-\(index)-\(fallbackFrom.number)-\(fallbackTo.number)-\(serviceDay ?? "unknown")"

            return OebbConnection(
                id: normalizedId,
                from: depStop,
                to: arrStop,
                sections: mappedSections.isEmpty ? nil : mappedSections,
                switches: connection.chg,
                duration: durationMillis,
                // Gate payload is alert-capable; use [] to explicitly represent "no alerts",
                // while nil remains "alert metadata unknown" (e.g. non-gate fallback payloads).
                serviceAlerts: mapGateConnectionAlerts(
                    connection,
                    himByIndex: himByIndex,
                    productsByIndex: productsByIndex
                ) ?? []
            )
        }
    }

    private func mapGateTripSection(
        _ section: OebbGateTripSection,
        defaultServiceDay: String?,
        locationsByIndex: [Int: OebbGateLocation],
        productsByIndex: [Int: OebbGateTripProduct],
        iconsByIndex: [Int: OebbGateTripIcon]
    ) -> OebbSection? {
        let sectionServiceDay = section.jny?.date ?? defaultServiceDay
        let stops = mapGateTripStops(
            section.jny?.stopL,
            serviceDay: sectionServiceDay,
            locationsByIndex: locationsByIndex
        )

        let from = mapGateTripStop(
            section.dep,
            serviceDay: sectionServiceDay,
            locationsByIndex: locationsByIndex
        ) ?? stops?.first
        let to = mapGateTripStop(
            section.arr,
            serviceDay: sectionServiceDay,
            locationsByIndex: locationsByIndex
        ) ?? stops?.last

        guard let from, let to else { return nil }

        let duration = gateDurationMillis(section.jny?.durS)
            ?? gateDurationFromStops(departure: from.departure, arrival: to.arrival)

        return OebbSection(
            from: from,
            to: to,
            duration: duration,
            category: mapGateTripCategory(section, productsByIndex: productsByIndex, iconsByIndex: iconsByIndex),
            type: section.type,
            hasRealtime: nil,
            stops: stops
        )
    }

    private func mapGateTripCategory(
        _ section: OebbGateTripSection,
        productsByIndex: [Int: OebbGateTripProduct],
        iconsByIndex: [Int: OebbGateTripIcon]
    ) -> OebbCategory? {
        if isWalkingGateSection(section) {
            return OebbCategory(name: "Walk", number: nil, shortName: "WALK", displayName: "Walk")
        }

        let productIndex = section.jny?.prodL?.first?.prodX ?? section.dep?.dProdX ?? section.arr?.aProdX
        guard let product = productIndex.flatMap({ productsByIndex[$0] }) else { return nil }

        let shortName = gateNormalizedString(product.prodCtx?.catOutS)
            ?? gateNormalizedString(product.prodCtx?.catIn)
            ?? gateLeadingLetters(in: product.nameS ?? product.name)
        let number = gateNormalizedString(product.number)
            ?? gateNormalizedString(product.prodCtx?.num)
            ?? gateTrailingNumber(in: product.nameS ?? product.name)
        let displayName = gateNormalizedString(product.prodCtx?.catOutL)
            ?? gateNormalizedString(product.nameS)
            ?? gateNormalizedString(product.name)

        let icon = product.icoX.flatMap { iconsByIndex[$0] }
        let backgroundHex = gateHex(icon?.bg)
        let foregroundHex = gateHex(icon?.fg)

        return OebbCategory(
            name: displayName ?? shortName,
            number: number,
            shortName: shortName,
            displayName: displayName ?? shortName,
            backgroundColor: backgroundHex,
            fontColor: foregroundHex,
            barColor: backgroundHex,
            train: true
        )
    }

    private func mapGateTripStops(
        _ stopRefs: [OebbGateTripStopRef]?,
        serviceDay: String?,
        locationsByIndex: [Int: OebbGateLocation]
    ) -> [OebbConnectionStop]? {
        guard let stopRefs, !stopRefs.isEmpty else { return nil }

        let mapped = stopRefs.compactMap {
            mapGateTripStop($0, serviceDay: serviceDay, locationsByIndex: locationsByIndex)
        }

        return mapped.isEmpty ? nil : mapped
    }

    private func mapGateTripStop(
        _ stopRef: OebbGateTripStopRef?,
        serviceDay: String?,
        locationsByIndex: [Int: OebbGateLocation],
        fallbackName: String? = nil,
        fallbackEsn: Int? = nil
    ) -> OebbConnectionStop? {
        guard let stopRef else { return nil }

        let location = stopRef.locX.flatMap { locationsByIndex[$0] }
        let name = gateNormalizedString(location?.name) ?? gateNormalizedString(fallbackName)
        guard let name else { return nil }

        let scheduledDeparture = gateIsoTimestamp(date: serviceDay, time: stopRef.dTimeS)
        let scheduledArrival = gateIsoTimestamp(date: serviceDay, time: stopRef.aTimeS)
        let realtimeDeparture = gateIsoTimestamp(date: serviceDay, time: stopRef.dTimeR)
        let realtimeArrival = gateIsoTimestamp(date: serviceDay, time: stopRef.aTimeR)

        let normalizedDeparturePlatform = gatePlatformText(stopRef.dPltfS) ?? gatePlatformText(stopRef.dPltfR)
        let normalizedArrivalPlatform = gatePlatformText(stopRef.aPltfS) ?? gatePlatformText(stopRef.aPltfR)
        let realtimeDeparturePlatform = gatePlatformText(stopRef.dPltfR)
        let realtimeArrivalPlatform = gatePlatformText(stopRef.aPltfR)
        let departurePlatformDeviation: String? =
            if let realtimeDeparturePlatform,
               let normalizedDeparturePlatform,
               realtimeDeparturePlatform != normalizedDeparturePlatform
            {
                realtimeDeparturePlatform
            } else {
                nil
            }
        let arrivalPlatformDeviation: String? =
            if let realtimeArrivalPlatform,
               let normalizedArrivalPlatform,
               realtimeArrivalPlatform != normalizedArrivalPlatform
            {
                realtimeArrivalPlatform
            } else {
                nil
            }

        return OebbConnectionStop(
            name: name,
            esn: gateNormalizedString(location?.extId).flatMap(Int.init) ?? fallbackEsn,
            departure: scheduledDeparture,
            arrival: scheduledArrival,
            departureRealtime: realtimeDeparture == scheduledDeparture ? nil : realtimeDeparture,
            arrivalRealtime: realtimeArrival == scheduledArrival ? nil : realtimeArrival,
            departureDelay: gateDelayMinutes(date: serviceDay, scheduledTime: stopRef.dTimeS, realtimeTime: stopRef.dTimeR),
            arrivalDelay: gateDelayMinutes(date: serviceDay, scheduledTime: stopRef.aTimeS, realtimeTime: stopRef.aTimeR),
            departurePlatform: normalizedDeparturePlatform,
            arrivalPlatform: normalizedArrivalPlatform,
            departurePlatformDeviation: departurePlatformDeviation,
            arrivalPlatformDeviation: arrivalPlatformDeviation
        )
    }

    private func mapGateConnectionAlerts(
        _ connection: OebbGateTripConnection,
        himByIndex: [Int: OebbGateHimMessage],
        productsByIndex: [Int: OebbGateTripProduct]
    ) -> [OebbServiceAlert]? {
        let sectionMessageRefs = (connection.secL ?? []).flatMap { section in
            ((section.msgL ?? []) + (section.jny?.msgL ?? [])).compactMap { message -> Int? in
                guard (message.type ?? "").uppercased() == "HIM" else { return nil }
                return message.himX
            }
        }
        let connectionMessageRefs = (connection.msgL ?? []).compactMap { message -> Int? in
            guard (message.type ?? "").uppercased() == "HIM" else { return nil }
            return message.himX
        }
        var refs = Set(sectionMessageRefs + connectionMessageRefs)

        // Some payload variants expose alert linkage via product.himIdL instead of msgL refs.
        // Keep this fallback strict to avoid assigning a train-specific disruption to unrelated connections.
        if refs.isEmpty {
            refs = gateFallbackAlertRefs(
                connection,
                himByIndex: himByIndex,
                productsByIndex: productsByIndex
            )
        }

        guard !refs.isEmpty else { return nil }

        var alerts: [OebbServiceAlert] = []
        var seenAlertIDs = Set<String>()

        for ref in refs.sorted() {
            guard let source = himByIndex[ref] else { continue }

            let id = gateNormalizedString(source.hid) ?? "gate-him-\(ref)"
            guard !seenAlertIDs.contains(id) else { continue }
            seenAlertIDs.insert(id)

            let title = gateNormalizedString(source.head) ?? "Service disruption"
            let message = gatePlainText(source.text)
            let startsAt = gateDateTime(date: source.sDate, time: source.sTime)
            let endsAt = gateDateTime(date: source.eDate, time: source.eTime)
            let priority = source.prio ?? 0
            let isActive = source.act ?? true

            alerts.append(
                OebbServiceAlert(
                    id: id,
                    title: title,
                    message: message,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    priority: priority,
                    isActive: isActive
                )
            )
        }

        return alerts.isEmpty ? nil : alerts.sorted(by: { $0.priority > $1.priority })
    }

    private func gateNormalizedHimProductId(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let digitsStart = trimmed.lastIndex(where: { !$0.isNumber }) {
            let candidate = String(trimmed[trimmed.index(after: digitsStart)...])
            return candidate.isEmpty ? nil : candidate
        }
        return trimmed
    }

    private func gateFallbackAlertRefs(
        _ connection: OebbGateTripConnection,
        himByIndex: [Int: OebbGateHimMessage],
        productsByIndex: [Int: OebbGateTripProduct]
    ) -> Set<Int> {
        var himIndicesById: [String: [Int]] = [:]
        for (index, him) in himByIndex {
            guard let hid = gateNormalizedString(him.hid) else { continue }
            himIndicesById[hid, default: []].append(index)
        }

        let productRefs = Set((connection.secL ?? []).flatMap { section in
            (section.jny?.prodL ?? []).compactMap(\.prodX)
                + [section.dep?.dProdX, section.arr?.aProdX].compactMap { $0 }
        } + [connection.dep?.dProdX, connection.arr?.aProdX].compactMap { $0 })
        let connectionProducts = productRefs.compactMap { productsByIndex[$0] }
        let connectionTrainTokens = Set(connectionProducts.flatMap(gateTrainTokens(for:)))
        let connectionLocIndices = gateConnectionLocationIndices(connection)

        var refs = Set<Int>()
        for product in connectionProducts {
            for productHimId in product.himIdL ?? [] {
                guard let normalizedId = gateNormalizedHimProductId(productHimId),
                      let himIndices = himIndicesById[normalizedId]
                else { continue }
                for himIndex in himIndices {
                    guard let him = himByIndex[himIndex],
                          gateFallbackAlertMatchesConnection(
                              him,
                              connectionTrainTokens: connectionTrainTokens,
                              connectionLocIndices: connectionLocIndices
                          )
                    else { continue }
                    refs.insert(himIndex)
                }
            }
        }

        return refs
    }

    private func gateConnectionLocationIndices(_ connection: OebbGateTripConnection) -> Set<Int> {
        Set((connection.secL ?? []).flatMap { section in
            var indices: [Int] = []
            if let depLocX = section.dep?.locX { indices.append(depLocX) }
            if let arrLocX = section.arr?.locX { indices.append(arrLocX) }
            indices.append(contentsOf: (section.jny?.stopL ?? []).compactMap(\.locX))
            return indices
        } + [connection.dep?.locX, connection.arr?.locX].compactMap { $0 })
    }

    private func gateFallbackAlertMatchesConnection(
        _ him: OebbGateHimMessage,
        connectionTrainTokens: Set<String>,
        connectionLocIndices: Set<Int>
    ) -> Bool {
        let alertTrainTokens = gateTrainTokens(in: "\(him.head ?? "") \(him.text ?? "")")
        if !alertTrainTokens.isEmpty {
            return !connectionTrainTokens.isDisjoint(with: alertTrainTokens)
        }

        if let fromLocX = him.fLocX, let toLocX = him.tLocX, fromLocX != toLocX {
            return connectionLocIndices.contains(fromLocX) && connectionLocIndices.contains(toLocX)
        }

        if let fromLocX = him.fLocX { return connectionLocIndices.contains(fromLocX) }
        if let toLocX = him.tLocX { return connectionLocIndices.contains(toLocX) }
        return true
    }

    private func gateTrainTokens(for product: OebbGateTripProduct) -> [String] {
        var tokens = Set<String>()
        let categoryTokens = [
            gateNormalizedString(product.prodCtx?.catOutS),
            gateNormalizedString(product.prodCtx?.catIn),
        ].compactMap { $0?.uppercased() }
        let numberTokens = [
            gateNormalizedString(product.number),
            gateNormalizedString(product.prodCtx?.num),
        ].compactMap { $0?.uppercased() }

        for category in categoryTokens {
            for number in numberTokens where !number.isEmpty {
                tokens.insert("\(category)\(number)")
            }
        }

        tokens.formUnion(gateTrainTokens(in: product.name))
        tokens.formUnion(gateTrainTokens(in: product.nameS))
        return Array(tokens)
    }

    private func gateTrainTokens(in value: String?) -> Set<String> {
        guard
            let regex = Self.gateTrainTokenRegex,
            let value = gateNormalizedString(value)
        else {
            return []
        }

        let uppercased = value.uppercased()
        let nsRange = NSRange(uppercased.startIndex..<uppercased.endIndex, in: uppercased)
        var tokens = Set<String>()

        for match in regex.matches(in: uppercased, range: nsRange) where match.numberOfRanges == 3 {
            guard
                let categoryRange = Range(match.range(at: 1), in: uppercased),
                let numberRange = Range(match.range(at: 2), in: uppercased)
            else { continue }
            let category = String(uppercased[categoryRange])
            let number = String(uppercased[numberRange])
            tokens.insert("\(category)\(number)")
        }

        return tokens
    }

    private func gateDelayMinutes(date: String?, scheduledTime: String?, realtimeTime: String?) -> Int? {
        guard
            let scheduled = gateDateTime(date: date, time: scheduledTime),
            let realtime = gateDateTime(date: date, time: realtimeTime)
        else {
            return nil
        }

        var normalizedRealtime = realtime
        if normalizedRealtime < scheduled {
            normalizedRealtime = normalizedRealtime.addingTimeInterval(86_400)
        }
        return max(0, Int(normalizedRealtime.timeIntervalSince(scheduled) / 60))
    }

    private func gateDurationMillis(_ rawValue: String?) -> Int? {
        guard let rawValue else { return nil }
        let digits = rawValue.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }

        let secondsPart = String(digits.suffix(2))
        let minutesPart = String(digits.dropLast(2).suffix(2))
        let hoursPart = String(digits.dropLast(4))

        guard let seconds = Int(secondsPart), let minutes = Int(minutesPart), let hours = Int(hoursPart) else {
            return nil
        }

        return ((hours * 3600) + (minutes * 60) + seconds) * 1000
    }

    private func gateDurationFromStops(departure: String?, arrival: String?) -> Int? {
        guard
            let departure,
            let arrival,
            let departureDate = dateFormatter.date(from: departure),
            let arrivalDate = dateFormatter.date(from: arrival)
        else {
            return nil
        }

        let duration = Int(arrivalDate.timeIntervalSince(departureDate) * 1000)
        return duration > 0 ? duration : nil
    }

    private func gateIsoTimestamp(date: String?, time: String?) -> String? {
        guard let date, let time else { return nil }
        let dateDigits = date.filter(\.isNumber)
        let timeDigits = time.filter(\.isNumber)
        guard dateDigits.count == 8, timeDigits.count >= 6 else { return nil }

        let year = dateDigits.prefix(4)
        let month = dateDigits.dropFirst(4).prefix(2)
        let day = dateDigits.suffix(2)

        let hour = timeDigits.prefix(2)
        let minute = timeDigits.dropFirst(2).prefix(2)
        let second = timeDigits.dropFirst(4).prefix(2)

        return "\(year)-\(month)-\(day)T\(hour):\(minute):\(second).000"
    }

    private func gateDateTime(date: String?, time: String?) -> Date? {
        guard let timestamp = gateIsoTimestamp(date: date, time: time) else { return nil }
        return dateFormatter.date(from: timestamp)
    }

    private func gatePlainText(_ value: String?) -> String {
        guard let value = gateNormalizedString(value) else { return "" }
        let withoutBreaks = value.replacingOccurrences(of: "<br>", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "<br/>", with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "<br />", with: "\n", options: [.caseInsensitive])
        let withoutTags = withoutBreaks.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return withoutTags.replacingOccurrences(of: "\\s+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gateHex(_ color: OebbGateTripRGBColor?) -> String? {
        guard
            let red = color?.r,
            let green = color?.g,
            let blue = color?.b,
            (0 ... 255).contains(red),
            (0 ... 255).contains(green),
            (0 ... 255).contains(blue)
        else {
            return nil
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func gateNormalizedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func gatePlatformText(_ value: OebbGateTextValue?) -> String? {
        guard let value else { return nil }
        if let type = gateNormalizedString(value.type), type.uppercased() != "PL" { return nil }
        return gateNormalizedString(value.txt)
    }

    private func gateLeadingLetters(in value: String?) -> String? {
        guard let value = gateNormalizedString(value) else { return nil }
        let letters = value.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }
        return String(letters).uppercased()
    }

    private func gateTrailingNumber(in value: String?) -> String? {
        guard let value = gateNormalizedString(value) else { return nil }
        let matches = value.split(whereSeparator: { !$0.isNumber })
        guard let lastNumber = matches.last else { return nil }
        let normalized = String(lastNumber)
        return normalized.isEmpty ? nil : normalized
    }

    private func makeGateLid(for station: OebbStationRef) -> String {
        let safeName = station.name.replacingOccurrences(of: "@", with: " ").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return "A=1@O=\(safeName)@X=\(station.longitude)@Y=\(station.latitude)@U=81@L=\(station.number)@"
    }

    private func isWalkingGateSection(_ section: OebbGateTripSection) -> Bool {
        let type = section.type?.lowercased() ?? ""
        return type.contains("walk") || type.contains("footpath")
    }

    private struct GateSnapshotMetadata: Codable {
        struct CursorInfo: Codable {
            let forward: String?
            let backward: String?
        }

        struct FileInfo: Codable {
            let request: String
            let response: String
        }

        let timestamp: Date
        let routeSignature: String
        let extractedConnectionIDs: [String]
        let cursors: CursorInfo
        let files: FileInfo
    }

    private func persistGateSnapshotArtifact(
        routeSignature: String,
        requestData: Data,
        responseData: Data,
        extractedConnectionIDs: [String],
        forwardCursor: String?,
        backwardCursor: String?
    ) {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let now = Date()
        let safeRoute = routeSignature.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let folderName = "\(Int(now.timeIntervalSince1970))_\(safeRoute)"
        let folderURL = baseURL.appendingPathComponent("oebb_gate_snapshots", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try requestData.write(to: folderURL.appendingPathComponent("request.json"), options: .atomic)
            try responseData.write(to: folderURL.appendingPathComponent("response.json"), options: .atomic)

            let metadata = GateSnapshotMetadata(
                timestamp: now,
                routeSignature: routeSignature,
                extractedConnectionIDs: extractedConnectionIDs,
                cursors: .init(forward: forwardCursor, backward: backwardCursor),
                files: .init(request: "request.json", response: "response.json")
            )
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: folderURL.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            // Best effort only.
        }
    }

    // MARK: - Private Helpers

    private func performAuthorized<T: Decodable>(
        url: URL?, method: String, body: Data? = nil, decode: T.Type
    ) async throws -> T {
        guard let url else { throw GleisError.networkError("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let authorized = try await applyAuth(to: request)
        return try await perform(authorized, decode: decode)
    }

    private func applyAuth(to request: URLRequest) async throws -> URLRequest {
        let session = try await ensureAuthSession()
        var req = request
        req.setValue(session.channel, forHTTPHeaderField: "Channel")
        req.setValue(session.accessToken, forHTTPHeaderField: "AccessToken")
        req.setValue(session.sessionId, forHTTPHeaderField: "SessionId")
        req.setValue("WEB_\(session.supportId)", forHTTPHeaderField: "x-ts-supportid")
        if let cookie = session.cookie, !cookie.isEmpty {
            req.setValue("ts-cookie=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        return req
    }

    private func perform<T: Decodable>(
        _ request: URLRequest,
        decode: T.Type,
        retryAuth: Bool = true,
        retryTransient: Bool = true,
        captureRaw: ((Data) -> Void)? = nil
    ) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GleisError.networkError("Invalid response") }

        if [401, 403, 440].contains(http.statusCode) {
            if retryAuth {
                authSession = nil
                try? storage.delete(forKey: StorageKey.oebbAuthSession.rawValue)
                return try await perform(
                    try await applyAuth(to: request),
                    decode: decode,
                    retryAuth: false,
                    retryTransient: retryTransient,
                    captureRaw: captureRaw
                )
            }
            throw GleisError.apiError(http.statusCode == 440 ? "Session expired" : "Auth failed")
        }

        if retryTransient, http.statusCode == 429 || (500 ... 504).contains(http.statusCode) {
            try? await Task.sleep(nanoseconds: http.statusCode == 429 ? 2_000_000_000 : 1_000_000_000)
            return try await perform(
                request,
                decode: decode,
                retryAuth: retryAuth,
                retryTransient: false,
                captureRaw: captureRaw
            )
        }

        guard (200 ..< 300).contains(http.statusCode) else { throw GleisError.apiError("HTTP \(http.statusCode)") }
        captureRaw?(data)
        return try decoder.decode(T.self, from: data)
    }

    private func ensureAuthSession() async throws -> OebbAuthSession {
        if let session = authSession, !session.isExpired { return session }
        let userId = authSession?.userId ?? makeUserId()
        let session = try await authenticate(userId: userId)
        authSession = session
        try? storage.save(session, forKey: StorageKey.oebbAuthSession.rawValue)
        return session
    }

    private func authenticate(userId: String) async throws -> OebbAuthSession {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/domain/v3/init"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "userId", value: userId)]
        guard let url = components?.url else { throw GleisError.networkError("Invalid auth URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("inet", forHTTPHeaderField: "Channel")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw GleisError.apiError("Auth failed")
        }

        let auth = try decoder.decode(OebbAuthResponse.self, from: data)
        let timeout = TimeInterval(max(auth.sessionTimeout ?? 2400, 0))
        return OebbAuthSession(
            userId: auth.userId ?? userId, accessToken: auth.accessToken, sessionId: auth.sessionId,
            supportId: auth.supportId, channel: auth.channel ?? "inet",
            cookie: extractCookie(from: http.allHeaderFields),
            expiresAt: Date().addingTimeInterval(max(timeout - 60, 0)), createdAt: Date()
        )
    }

    private func extractCookie(from headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers where String(describing: key).lowercased() == "set-cookie" {
            let header = String(describing: value)
            if let range = header.range(of: "ts-cookie=") {
                return header[range.upperBound...].split(separator: ";").first.map(String.init)
            }
        }
        return nil
    }

    private func makeUserId() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        func random(_ n: Int) -> String { String((0 ..< n).map { _ in chars.randomElement()! }).lowercased() }
        return "anonym-\(random(8))-\(random(4))-\(random(2))"
    }

    private func makeGateRequestId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 16).map { _ in chars.randomElement()! })
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
