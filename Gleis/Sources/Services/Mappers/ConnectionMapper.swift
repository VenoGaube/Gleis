import Foundation

enum ConnectionMapper {
    static func map(
        _ connection: OebbConnection, from: Station, to: Station, transportType: TransportType
    ) -> TrainConnection {
        let sections = connection.sections ?? []
        let departureTime = parseDate(connection.from.departure) ?? parseDate(sections.first?.from.departure) ?? Date()
        let arrivalTime =
            parseDate(connection.to.arrival) ?? parseDate(sections.last?.to.arrival)
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

        return TrainConnection(
            id: connection.id, lineNumber: lineInfo.number, trainType: lineInfo.trainType,
            departureTime: departureTime, arrivalTime: arrivalTime, departureStation: from, arrivalStation: to,
            platform: platform, delay: delayMinutes, status: status, transfers: transfers,
            legs: mapLegs(
                sections, transportType: transportType, fallbackFrom: from, fallbackTo: to,
                fallbackLineNumber: lineInfo.number, fallbackPlatform: platform, fallbackDeparture: departureTime,
                fallbackArrival: arrivalTime
            )
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

    // MARK: - Private Helpers

    private static func primaryCategory(in connection: OebbConnection) -> OebbCategory? {
        let sections = connection.sections ?? []
        return sections.first { !isWalkingCategory($0.category) && $0.category != nil }?.category
            ?? sections.first?.category
    }

    private static func lineInfo(for category: OebbCategory?) -> (number: String, trainType: TrainType, isWalking: Bool) {
        guard let category else { return ("CONNECTION", .other, false) }
        if isWalkingCategory(category) { return ("WALK", .other, true) }

        let name = category.shortName ?? category.displayName ?? category.name
        let number = category.number
        let trainType = TrainType.from(category: name)
        let lineNumber: String =
            if let number, !number.isEmpty {
                number.rangeOfCharacter(from: .letters) != nil ? number : (name.map { "\($0) \(number)" } ?? number)
            } else { name ?? "Connection" }
        return (lineNumber.uppercased(), trainType, false)
    }

    private static func isWalkingCategory(_ category: OebbCategory?) -> Bool {
        guard let category else { return false }
        let name = (category.shortName ?? category.displayName ?? category.name ?? "").uppercased()
        return name == "W" || name == "WALK"
    }

    private static func mapLegs(
        _ sections: [OebbSection], transportType: TransportType, fallbackFrom: Station, fallbackTo: Station,
        fallbackLineNumber: String, fallbackPlatform: String?, fallbackDeparture: Date?, fallbackArrival: Date?
    ) -> [ConnectionLeg] {
        if sections.isEmpty {
            return [
                ConnectionLeg(
                    from: fallbackFrom, to: fallbackTo, departureTime: fallbackDeparture, arrivalTime: fallbackArrival,
                    platform: fallbackPlatform, lineNumber: fallbackLineNumber, isWalking: false,
                    duration: fallbackDeparture.flatMap { dep in fallbackArrival.map { $0.timeIntervalSince(dep) } },
                    finalDestination: fallbackTo.name
                ),
            ]
        }
        return sections.map { section in
            let fromStation = mapStop(section.from, fallbackName: fallbackFrom.name, transportType: transportType)
            let toStation = mapStop(section.to, fallbackName: fallbackTo.name, transportType: transportType)
            let info = lineInfo(for: section.category)
            let legDelay = section.from.departureDelay ?? section.to.arrivalDelay
            let intermediateStops = mapIntermediateStops(section.stops)
            return ConnectionLeg(
                from: fromStation, to: toStation,
                departureTime: parseDate(section.from.departureRealtime) ?? parseDate(section.from.departure),
                arrivalTime: parseDate(section.to.arrivalRealtime) ?? parseDate(section.to.arrival),
                platform: section.from.departurePlatformDeviation ?? section.from.departurePlatform,
                lineNumber: info.number, trainType: info.trainType, isWalking: info.isWalking,
                duration: section.duration.map { TimeInterval($0) / 1000 },
                finalDestination: info.isWalking ? nil : toStation.name,
                platformChanged: section.from.departurePlatformDeviation != nil, stopCount: section.stopCount,
                delayMinutes: legDelay.map { max(0, $0) }, intermediateStops: intermediateStops
            )
        }
    }

    private static func mapIntermediateStops(_ stops: [OebbConnectionStop]?) -> [IntermediateStop] {
        guard let stops, stops.count > 2 else { return [] }
        // Exclude first and last stops (they are the leg's from/to stations)
        return stops.dropFirst().dropLast().compactMap { stop -> IntermediateStop? in
            guard let name = stop.name, !name.isEmpty else { return nil }
            return IntermediateStop(
                id: stop.esn.map(String.init) ?? UUID().uuidString, name: name, arrivalTime: parseDate(stop.arrival),
                departureTime: parseDate(stop.departure), arrivalDelay: stop.arrivalDelay,
                departureDelay: stop.departureDelay, platform: stop.arrivalPlatform
            )
        }
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

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.date(from: value)
    }
}
