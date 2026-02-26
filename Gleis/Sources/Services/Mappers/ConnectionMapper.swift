import Foundation

enum ConnectionMapper {
    private static let secondsPerDay: TimeInterval = 86_400
    private static let maxDayRollovers = 3

    private static let parseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    private static let parseDateLock = NSLock()

    static func map(
        _ connection: OebbConnection, from: Station, to: Station, transportType: TransportType
    ) -> TrainConnection {
        let sections = connection.sections ?? []
        let scheduledDeparture =
            parseDate(connection.from.departure)
            ?? parseDate(sections.first?.from.departure)
        let departureDelay =
            connection.from.departureDelay
            ?? sections.first?.from.departureDelay
            ?? connection.to.arrivalDelay
            ?? sections.last?.to.arrivalDelay
        let departureTime =
            parseDate(connection.from.departureRealtime)
            ?? parseDate(sections.first?.from.departureRealtime)
            ?? delayedDate(base: scheduledDeparture, delayMinutes: departureDelay)
            ?? scheduledDeparture
            ?? Date()

        let scheduledArrival =
            parseDate(connection.to.arrival)
            ?? parseDate(sections.last?.to.arrival)
        let arrivalDelay =
            connection.to.arrivalDelay
            ?? sections.last?.to.arrivalDelay
            ?? connection.from.departureDelay
            ?? sections.first?.from.departureDelay
        let arrivalTime =
            parseDate(connection.to.arrivalRealtime)
            ?? parseDate(sections.last?.to.arrivalRealtime)
            ?? delayedDate(base: scheduledArrival, delayMinutes: arrivalDelay)
            ?? scheduledArrival
            ?? departureTime.addingTimeInterval(TimeInterval((connection.duration ?? 0) / 1000))
        let platform =
            connection.from.departurePlatformDeviation ?? connection.from.departurePlatform ?? sections.first?.from
                .departurePlatformDeviation ?? sections.first?.from.departurePlatform
        let lineInfo = lineInfo(for: primaryCategory(in: connection))
        let delayMinutes = delayMinutes(for: connection)
        let status =
            connectionCancelled(connection) ? ConnectionStatus.cancelled : (delayMinutes > 0 ? .delayed : .onTime)
        let transferSections = sections.filter { $0.category != nil && !isWalkingCategory($0.category) }
        let transfers = connection.switches ?? max(0, transferSections.count - 1)
        let mappedLegs = mapLegs(
            sections, transportType: transportType, fallbackFrom: from, fallbackTo: to,
            fallbackLineNumber: lineInfo.number, fallbackLineColors: lineInfo.lineColors,
            fallbackPlatform: platform, fallbackDeparture: departureTime, fallbackArrival: arrivalTime
        )
        let normalized = normalizeConnectionChronology(
            departure: departureTime,
            arrival: arrivalTime,
            legs: mappedLegs
        )

        return TrainConnection(
            id: connection.id, lineNumber: lineInfo.number, trainType: lineInfo.trainType,
            lineColors: lineInfo.lineColors,
            departureTime: normalized.departure, arrivalTime: normalized.arrival, departureStation: from, arrivalStation: to,
            platform: platform, delay: delayMinutes, status: status, transfers: transfers,
            legs: normalized.legs,
            serviceAlerts: mapServiceAlerts(connection.serviceAlerts)
        )
    }

    static func mapStation(_ station: OebbStation, transportType: TransportType) -> Station {
        let name =
            station.name?.isEmpty == false
                ? station.name! : (station.meta?.isEmpty == false ? station.meta! : "Unknown Station")

        // Only create coordinate if both latitude and longitude are non-zero
        // OEBB API returns 0,0 for stations without coordinate data (e.g., some non-Austrian stations)
        let coordinate: Station.Coordinate? =
            if station.latitude != 0, station.longitude != 0 {
                Station.Coordinate(
                    latitude: Double(station.latitude) / 1_000_000, longitude: Double(station.longitude) / 1_000_000
                )
            } else {
                nil
            }

        return Station(
            id: String(station.number), name: name, coordinate: coordinate, transportTypes: [transportType], lines: []
        )
    }

    static func enrichConnection(_ connection: TrainConnection, detail: OebbConnectionDetailResponse) -> TrainConnection {
        guard !connection.legs.isEmpty, !detail.sections.isEmpty else { return connection }

        var enrichedLegs = connection.legs
        var usedDetailIndices = Set<Int>()
        var fallbackDetailCursor = 0

        for legIndex in enrichedLegs.indices where !enrichedLegs[legIndex].isWalking {
            let leg = enrichedLegs[legIndex]
            guard let detailIndex = findMatchingDetailSectionIndex(
                for: leg,
                detailSections: detail.sections,
                usedDetailIndices: &usedDetailIndices,
                fallbackCursor: &fallbackDetailCursor
            ) else { continue }

            let detailSection = detail.sections[detailIndex]
            let mappedStops = mapIntermediateStops(
                detailSection.intermediatePoints,
                connectionId: connection.id,
                fromName: leg.from.name,
                toName: leg.to.name,
                fallbackDelayMinutes: leg.delayMinutes
            )
            let resolvedStops = mappedStops.isEmpty ? leg.intermediateStops : mappedStops
            let resolvedStopCount: Int? = {
                if !resolvedStops.isEmpty { return resolvedStops.count }
                // If detail section matched but has no intermediate points, this is a known 0-halt leg.
                return 0
            }()

            enrichedLegs[legIndex] = ConnectionLeg(
                id: leg.id, from: leg.from, to: leg.to, departureTime: leg.departureTime, arrivalTime: leg.arrivalTime,
                platform: leg.platform, arrivalPlatform: leg.arrivalPlatform, lineNumber: leg.lineNumber,
                trainType: leg.trainType, lineColors: leg.lineColors, isWalking: leg.isWalking, duration: leg.duration,
                finalDestination: leg.finalDestination, platformChanged: leg.platformChanged,
                stopCount: resolvedStopCount,
                delayMinutes: leg.delayMinutes,
                departureDelayMinutes: leg.departureDelayMinutes,
                arrivalDelayMinutes: leg.arrivalDelayMinutes,
                intermediateStops: resolvedStops
            )
        }

        return TrainConnection(
            id: connection.id, lineNumber: connection.lineNumber, trainType: connection.trainType,
            lineColors: connection.lineColors,
            departureTime: connection.departureTime, arrivalTime: connection.arrivalTime,
            departureStation: connection.departureStation, arrivalStation: connection.arrivalStation,
            platform: connection.platform, delay: connection.delay, status: connection.status,
            transfers: connection.transfers, legs: enrichedLegs,
            serviceAlerts: connection.serviceAlerts
        )
    }

    // MARK: - Private Helpers

    private static func primaryCategory(in connection: OebbConnection) -> OebbCategory? {
        let sections = connection.sections ?? []
        return sections.first { !isWalkingCategory($0.category) && $0.category != nil }?.category
            ?? sections.first?.category
    }

    private static func lineInfo(
        for category: OebbCategory?
    ) -> (number: String, trainType: TrainType, lineColors: TrainLineColors?, isWalking: Bool) {
        guard let category else { return ("CONNECTION", .other, nil, false) }
        if isWalkingCategory(category) { return ("WALK", .other, nil, true) }

        let name = category.shortName ?? category.displayName ?? category.name
        let number = category.number
        let lineNumber: String =
            if let number, !number.isEmpty {
                number.rangeOfCharacter(from: .letters) != nil ? number : (name.map { "\($0) \(number)" } ?? number)
            } else { name ?? "Connection" }
        let normalizedLineNumber = lineNumber.uppercased()
        let trainType = TrainType.from(category: category, fallbackLineNumber: normalizedLineNumber)
        return (normalizedLineNumber, trainType, category.lineColors ?? trainType.colors, false)
    }

    private static func isWalkingCategory(_ category: OebbCategory?) -> Bool {
        guard let category else { return false }
        let name = (category.shortName ?? category.displayName ?? category.name ?? "").uppercased()
        return name == "W" || name == "WALK"
    }

    private static func mapLegs(
        _ sections: [OebbSection], transportType: TransportType, fallbackFrom: Station, fallbackTo: Station,
        fallbackLineNumber: String, fallbackLineColors: TrainLineColors?, fallbackPlatform: String?,
        fallbackDeparture: Date?, fallbackArrival: Date?
    ) -> [ConnectionLeg] {
        if sections.isEmpty {
            return [
                ConnectionLeg(
                    from: fallbackFrom, to: fallbackTo, departureTime: fallbackDeparture, arrivalTime: fallbackArrival,
                    platform: fallbackPlatform, lineNumber: fallbackLineNumber, lineColors: fallbackLineColors,
                    isWalking: false,
                    duration: fallbackDeparture.flatMap { dep in fallbackArrival.map { $0.timeIntervalSince(dep) } },
                    finalDestination: fallbackTo.name
                ),
            ]
        }
        return sections.map { section in
            let fromStation = mapStop(section.from, fallbackName: fallbackFrom.name, transportType: transportType)
            let toStation = mapStop(section.to, fallbackName: fallbackTo.name, transportType: transportType)
            let departurePlatform = section.from.departurePlatformDeviation ?? section.from.departurePlatform
            let arrivalPlatform = section.to.arrivalPlatformDeviation ?? section.to.arrivalPlatform
            let info = lineInfo(for: section.category)
            let legDelay = section.from.departureDelay ?? section.to.arrivalDelay
            let scheduledDeparture = parseDate(section.from.departure)
            let scheduledArrival = parseDate(section.to.arrival)
            let realtimeDeparture = parseDate(section.from.departureRealtime)
            let realtimeArrival = parseDate(section.to.arrivalRealtime)
            let departureDelay =
                section.from.departureDelay
                ?? realtimeDelayMinutes(scheduled: scheduledDeparture, realtime: realtimeDeparture)
                ?? legDelay
            let arrivalDelay =
                section.to.arrivalDelay
                ?? realtimeDelayMinutes(scheduled: scheduledArrival, realtime: realtimeArrival)
                ?? legDelay
            let normalizedDepartureDelay = departureDelay.map { max(0, $0) }
            let normalizedArrivalDelay = arrivalDelay.map { max(0, $0) }
            let normalizedLegDelay: Int? = {
                let combined = max(
                    normalizedDepartureDelay ?? 0,
                    normalizedArrivalDelay ?? 0,
                    max(0, legDelay ?? 0)
                )
                return combined > 0 ? combined : nil
            }()
            let stopIdPrefix = makeIntermediateStopPrefix(
                fromStationId: fromStation.id,
                toStationId: toStation.id,
                lineNumber: info.number,
                departure: section.from.departure,
                arrival: section.to.arrival
            )
            let intermediateStops = mapIntermediateStops(
                section.stops,
                fromName: fromStation.name,
                toName: toStation.name,
                fromEsn: section.from.esn,
                toEsn: section.to.esn,
                stopIdPrefix: stopIdPrefix,
                fallbackDelayMinutes: normalizedLegDelay
            )
            let stopCount = section.stopCount ?? (intermediateStops.isEmpty ? nil : intermediateStops.count)
            return ConnectionLeg(
                from: fromStation, to: toStation,
                departureTime:
                    realtimeDeparture
                    ?? delayedDate(base: scheduledDeparture, delayMinutes: departureDelay)
                    ?? scheduledDeparture,
                arrivalTime:
                    realtimeArrival
                    ?? delayedDate(base: scheduledArrival, delayMinutes: arrivalDelay)
                    ?? scheduledArrival,
                platform: departurePlatform,
                arrivalPlatform: arrivalPlatform,
                lineNumber: info.number, trainType: info.trainType, lineColors: info.lineColors,
                isWalking: info.isWalking,
                duration: section.duration.map { max(0, TimeInterval($0) / 1000) },
                finalDestination: info.isWalking ? nil : toStation.name,
                platformChanged: section.from.departurePlatformDeviation != nil, stopCount: stopCount,
                delayMinutes: normalizedLegDelay,
                departureDelayMinutes: normalizedDepartureDelay,
                arrivalDelayMinutes: normalizedArrivalDelay,
                intermediateStops: intermediateStops
            )
        }
    }

    private static func mapIntermediateStops(
        _ stops: [OebbConnectionStop]?,
        fromName: String,
        toName: String,
        fromEsn: Int?,
        toEsn: Int?,
        stopIdPrefix: String,
        fallbackDelayMinutes: Int?
    ) -> [IntermediateStop] {
        guard let stops, !stops.isEmpty else { return [] }

        // Most passlists include section endpoints; only trim those when they match leg boundaries.
        let normalizedFrom = normalizeStationName(fromName)
        let normalizedTo = normalizeStationName(toName)
        let firstName = normalizeStationName(stops.first?.name)
        let lastName = normalizeStationName(stops.last?.name)
        let firstEsn = stops.first?.esn
        let lastEsn = stops.last?.esn
        let matchesByName = firstName == normalizedFrom && lastName == normalizedTo
        let matchesByEsn =
            fromEsn != nil && toEsn != nil && firstEsn == fromEsn && lastEsn == toEsn
        let includesEndpoints = (matchesByName || matchesByEsn) && stops.count >= 2

        let candidates: ArraySlice<OebbConnectionStop> = includesEndpoints ? stops.dropFirst().dropLast() : stops[...]
        guard !candidates.isEmpty else { return [] }

        return candidates.enumerated().compactMap { index, stop -> IntermediateStop? in
            guard let name = stop.name, !name.isEmpty else { return nil }
            let scheduledArrival = parseDate(stop.arrival)
            let realtimeArrival = parseDate(stop.arrivalRealtime)
            let scheduledDeparture = parseDate(stop.departure)
            let realtimeDeparture = parseDate(stop.departureRealtime)
            let arrivalDelay = stop.arrivalDelay ?? fallbackDelayMinutes
            let departureDelay = stop.departureDelay ?? fallbackDelayMinutes
            return IntermediateStop(
                id: stableIntermediateStopID(
                    prefix: stopIdPrefix,
                    index: index,
                    esn: stop.esn,
                    name: name,
                    arrival: stop.arrival,
                    departure: stop.departure
                ),
                name: name,
                arrivalTime:
                    realtimeArrival
                    ?? delayedDate(base: scheduledArrival, delayMinutes: arrivalDelay)
                    ?? scheduledArrival,
                departureTime:
                    realtimeDeparture
                    ?? delayedDate(base: scheduledDeparture, delayMinutes: departureDelay)
                    ?? scheduledDeparture,
                arrivalDelay: arrivalDelay,
                departureDelay: departureDelay,
                platform: stop.arrivalPlatform
            )
        }
    }

    private static func mapIntermediateStops(
        _ stops: [OebbConnectionDetailIntermediatePoint],
        connectionId: String,
        fromName: String,
        toName: String,
        fallbackDelayMinutes: Int?
    ) -> [IntermediateStop] {
        guard !stops.isEmpty else { return [] }
        let prefix = makeIntermediateStopPrefix(
            fromStationId: connectionId,
            toStationId: "\(fromName)-\(toName)",
            lineNumber: "detail",
            departure: nil,
            arrival: nil
        )

        return stops.enumerated().compactMap { index, stop in
            guard let rawName = stop.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
                return nil
            }

            let scheduledArrival = parseDate(stop.arrival)
            let realtimeArrival = parseDate(stop.realtimeInformation?.arrival)
            let scheduledDeparture = parseDate(stop.departure)
            let realtimeDeparture = parseDate(stop.realtimeInformation?.departure)
            let arrivalDelay = realtimeDelayMinutes(scheduled: scheduledArrival, realtime: realtimeArrival)
                ?? fallbackDelayMinutes
            let departureDelay = realtimeDelayMinutes(scheduled: scheduledDeparture, realtime: realtimeDeparture)
                ?? fallbackDelayMinutes

            return IntermediateStop(
                id: stableIntermediateStopID(
                    prefix: prefix,
                    index: index,
                    esn: nil,
                    name: rawName,
                    arrival: stop.realtimeInformation?.arrival ?? stop.arrival,
                    departure: stop.realtimeInformation?.departure ?? stop.departure
                ),
                name: rawName,
                arrivalTime:
                    realtimeArrival
                    ?? delayedDate(base: scheduledArrival, delayMinutes: arrivalDelay)
                    ?? scheduledArrival,
                departureTime:
                    realtimeDeparture
                    ?? delayedDate(base: scheduledDeparture, delayMinutes: departureDelay)
                    ?? scheduledDeparture,
                arrivalDelay: arrivalDelay,
                departureDelay: departureDelay,
                platform: stop.realtimeInformation?.arrivalPlatform ?? stop.realtimeInformation?.departurePlatform
            )
        }
    }

    private static func realtimeDelayMinutes(scheduled: Date?, realtime: Date?) -> Int? {
        guard let scheduled, let realtime else { return nil }
        return max(0, Int(realtime.timeIntervalSince(scheduled) / 60))
    }

    private static func makeIntermediateStopPrefix(
        fromStationId: String,
        toStationId: String,
        lineNumber: String,
        departure: String?,
        arrival: String?
    ) -> String {
        let fromToken = normalizedIdentifierToken(fromStationId)
        let toToken = normalizedIdentifierToken(toStationId)
        let lineToken = normalizedIdentifierToken(lineNumber)
        let departureToken = normalizedIdentifierToken(departure)
        let arrivalToken = normalizedIdentifierToken(arrival)
        return "\(fromToken)-\(toToken)-\(lineToken)-\(departureToken)-\(arrivalToken)"
    }

    private static func stableIntermediateStopID(
        prefix: String,
        index: Int,
        esn: Int?,
        name: String,
        arrival: String?,
        departure: String?
    ) -> String {
        let esnToken = esn.map(String.init) ?? "na"
        let nameToken = normalizedIdentifierToken(name)
        let arrivalToken = normalizedIdentifierToken(arrival)
        let departureToken = normalizedIdentifierToken(departure)
        return "\(prefix)-\(index)-\(esnToken)-\(nameToken)-\(arrivalToken)-\(departureToken)"
    }

    private static func normalizedIdentifierToken(_ value: String?) -> String {
        guard let value else { return "na" }
        let token = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).filter {
            $0.isLetter || $0.isNumber
        }
        return token.isEmpty ? "na" : token
    }

    private static func findMatchingDetailSectionIndex(
        for leg: ConnectionLeg, detailSections: [OebbConnectionDetailSection], usedDetailIndices: inout Set<Int>,
        fallbackCursor: inout Int
    ) -> Int? {
        let normalizedFrom = normalizeStationName(leg.from.name)
        let normalizedTo = normalizeStationName(leg.to.name)

        var bestIndex: Int?
        var bestScore = 0

        for index in detailSections.indices where !usedDetailIndices.contains(index) {
            let section = detailSections[index]
            guard !isWalkingDetailSection(section) else { continue }
            let fromScore =
                normalizeStationName(section.from?.name).map { $0 == normalizedFrom ? 1 : 0 } ?? 0
            let toScore =
                normalizeStationName(section.to?.name).map { $0 == normalizedTo ? 1 : 0 } ?? 0
            let score = fromScore + toScore
            if score > bestScore {
                bestScore = score
                bestIndex = index
                if score == 2 { break }
            }
        }

        if let bestIndex {
            usedDetailIndices.insert(bestIndex)
            return bestIndex
        }

        while fallbackCursor < detailSections.count {
            let index = fallbackCursor
            fallbackCursor += 1
            if usedDetailIndices.contains(index) { continue }
            if isWalkingDetailSection(detailSections[index]) { continue }
            usedDetailIndices.insert(index)
            return index
        }
        return nil
    }

    private static func normalizeStationName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).filter {
            $0.isLetter || $0.isNumber
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isWalkingDetailSection(_ section: OebbConnectionDetailSection) -> Bool {
        let type = section.type?.lowercased() ?? ""
        if type.contains("walk") || type == "footpath" { return true }
        let rideShortName = section.ride?.shortName?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return rideShortName == "W" || rideShortName == "WALK"
    }

    private static func mapStop(
        _ stop: OebbConnectionStop, fallbackName: String, transportType: TransportType
    ) -> Station {
        let name = stop.name?.isEmpty == false ? stop.name! : fallbackName
        let id = stop.esn.map(String.init) ?? fallbackName.lowercased().replacingOccurrences(of: " ", with: "_")
        return Station(id: id, name: name, coordinate: nil, transportTypes: [transportType], lines: [])
    }

    private static func connectionCancelled(_ connection: OebbConnection) -> Bool {
        if connection.from.cancelled == true || connection.to.cancelled == true { return true }
        return (connection.sections ?? []).contains { $0.from.cancelled == true || $0.to.cancelled == true }
    }

    private static func mapServiceAlerts(_ alerts: [OebbServiceAlert]?) -> [ServiceAlert]? {
        guard let alerts else { return nil }
        return alerts.map {
            ServiceAlert(
                id: $0.id,
                title: $0.title,
                message: $0.message,
                startsAt: $0.startsAt,
                endsAt: $0.endsAt,
                priority: $0.priority,
                isActive: $0.isActive
            )
        }
    }

    private static func delayMinutes(for connection: OebbConnection) -> Int {
        if let delay = connection.from.departureDelay ?? connection.to.arrivalDelay { return max(0, delay) }
        let sections = connection.sections ?? []
        if let delay = sections.first?.from.departureDelay ?? sections.last?.to.arrivalDelay { return max(0, delay) }
        if let scheduled = parseDate(connection.from.departure),
           let realtime = parseDate(connection.from.departureRealtime)
        {
            return max(0, Int(realtime.timeIntervalSince(scheduled) / 60))
        }
        return 0
    }

    private static func delayedDate(base: Date?, delayMinutes: Int?) -> Date? {
        guard let base else { return nil }
        let minutes = max(0, delayMinutes ?? 0)
        guard minutes > 0 else { return base }
        return base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private static func normalizeConnectionChronology(
        departure: Date,
        arrival: Date,
        legs: [ConnectionLeg]
    ) -> (departure: Date, arrival: Date, legs: [ConnectionLeg]) {
        var normalizedLegs: [ConnectionLeg] = []
        var cursor: Date = departure

        for leg in legs {
            let normalizedDeparture = normalizedForward(leg.departureTime, relativeTo: cursor)
            let normalizedArrival = normalizedForward(
                leg.arrivalTime,
                relativeTo: normalizedDeparture ?? cursor
            )
            let normalizedStops = normalizeIntermediateStopsChronology(
                leg.intermediateStops,
                relativeTo: normalizedDeparture ?? cursor
            )
            let normalizedDuration: TimeInterval? = {
                if let dep = normalizedDeparture, let arr = normalizedArrival {
                    return max(0, arr.timeIntervalSince(dep))
                }
                if let duration = leg.duration {
                    return max(0, duration)
                }
                return nil
            }()

            normalizedLegs.append(
                ConnectionLeg(
                    id: leg.id,
                    from: leg.from,
                    to: leg.to,
                    departureTime: normalizedDeparture,
                    arrivalTime: normalizedArrival,
                    platform: leg.platform,
                    arrivalPlatform: leg.arrivalPlatform,
                    lineNumber: leg.lineNumber,
                    trainType: leg.trainType,
                    lineColors: leg.lineColors,
                    isWalking: leg.isWalking,
                    duration: normalizedDuration,
                    finalDestination: leg.finalDestination,
                    platformChanged: leg.platformChanged,
                    stopCount: leg.stopCount,
                    delayMinutes: leg.delayMinutes,
                    departureDelayMinutes: leg.departureDelayMinutes,
                    arrivalDelayMinutes: leg.arrivalDelayMinutes,
                    intermediateStops: normalizedStops
                )
            )

            if let normalizedArrival {
                cursor = normalizedArrival
            } else if let normalizedDeparture {
                cursor = normalizedDeparture
            }
        }

        let normalizedDeparture = normalizedLegs.first?.departureTime ?? departure
        var normalizedArrival = normalizedForward(arrival, relativeTo: normalizedDeparture) ?? arrival
        if let lastLegArrival = normalizedLegs.last?.arrivalTime, lastLegArrival > normalizedArrival {
            normalizedArrival = lastLegArrival
        }

        return (normalizedDeparture, normalizedArrival, normalizedLegs)
    }

    private static func normalizeIntermediateStopsChronology(
        _ stops: [IntermediateStop],
        relativeTo start: Date
    ) -> [IntermediateStop] {
        guard !stops.isEmpty else { return [] }

        var normalized: [IntermediateStop] = []
        var cursor = start

        for stop in stops {
            let arrival = normalizedForward(stop.arrivalTime, relativeTo: cursor)
            let departure = normalizedForward(stop.departureTime, relativeTo: arrival ?? cursor)
            normalized.append(
                IntermediateStop(
                    id: stop.id,
                    name: stop.name,
                    arrivalTime: arrival,
                    departureTime: departure,
                    arrivalDelay: stop.arrivalDelay,
                    departureDelay: stop.departureDelay,
                    platform: stop.platform
                )
            )

            if let departure {
                cursor = departure
            } else if let arrival {
                cursor = arrival
            }
        }

        return normalized
    }

    private static func normalizedForward(_ value: Date?, relativeTo reference: Date?) -> Date? {
        guard let value else { return nil }
        guard let reference else { return value }
        guard value < reference else { return value }

        var adjusted = value
        var rollovers = 0
        while adjusted < reference, rollovers < maxDayRollovers {
            adjusted = adjusted.addingTimeInterval(secondsPerDay)
            rollovers += 1
        }

        return adjusted < reference ? reference : adjusted
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        parseDateLock.lock()
        defer { parseDateLock.unlock() }
        return parseDateFormatter.date(from: value)
    }
}
