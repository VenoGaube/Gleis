import Foundation

/// Service to enrich OEBB train connection data with information from the Slovenian Railways API
/// Uses SŽ data to supplement missing fields like platforms and delays
enum SzDataEnricher {
    /// Station ID mapping between OEBB (ESN) and SŽ station codes
    /// OEBB ESN IDs for Slovenia start with 83 (country code)
    /// SŽ uses their own internal station codes
    /// NOTE: These mappings may need to be verified/updated by querying both APIs
    private static let stationMapping: [Int: String] = [
        // Ljubljana area
        8_300_001: "42300", // Ljubljana (main station)
        8_300_002: "42357", // Ljubljana Brinje
        8_300_003: "42306", // Ljubljana Šiška
        8_300_004: "42316", // Ljubljana Vič
        8_300_005: "42391", // Ljubljana Črnuče
        8_300_006: "42308", // Ljubljana Rakovnik
        8_300_007: "42310", // Ljubljana Moste
        8_300_008: "42312", // Ljubljana Polje
        8_300_009: "42314", // Ljubljana Zalog

        // Maribor area
        8_300_100: "43000", // Maribor (main station)
        8_300_101: "43001", // Maribor Tezno
        8_300_102: "43002", // Maribor Studenci

        // Major stations
        8_300_200: "43300", // Celje
        8_300_210: "44100", // Koper
        8_300_220: "42700", // Novo mesto
        8_300_230: "43500", // Ptuj
        8_300_240: "42600", // Kranj
        8_300_250: "43600", // Murska Sobota
        8_300_260: "42050", // Jesenice
        8_300_270: "42100", // Sežana
        8_300_280: "42150", // Divača
        8_300_290: "42120", // Postojna
        8_300_300: "43200", // Zidani Most
        8_300_310: "43350", // Laško
        8_300_320: "43400", // Pragersko
        8_300_330: "42450", // Litija
        8_300_340: "42500", // Zagorje ob Savi
        8_300_350: "42550", // Trbovlje
        8_300_360: "42580", // Hrastnik
        8_300_370: "43100", // Šentjur
        8_300_380: "43700", // Lendava
        8_300_390: "42180", // Pivka
        8_300_400: "42400", // Grosuplje
        8_300_410: "42380", // Domžale
        8_300_420: "42350", // Kamnik
        8_300_430: "42650", // Škofja Loka
        8_300_440: "44000", // Kočevje
        8_300_450: "42800", // Sevnica
        8_300_460: "42850", // Brežice
        8_300_470: "43450", // Slovenska Bistrica

        // Border stations
        8_300_500: "42010", // Jesenice (AT border direction)
        8_300_510: "42200", // Sežana (IT border direction)
        8_300_520: "43800", // Hodoš (HU border)
        8_300_530: "42900", // Dobova (HR border)
        8_300_540: "42990" // Metlika (HR border)
    ]

    /// Cached name-based station lookup for dynamic matching
    /// Used when OEBB ESN is not in the static mapping
    private static var stationNameCache: [String: String] = [:]

    /// Attempts to match a station by name similarity
    /// - Parameter name: Station name from OEBB
    /// - Returns: SŽ station ID if a match is found in cache
    static func szStationIdByName(_ name: String) -> String? {
        let normalizedName = name.lowercased()
            .replacingOccurrences(of: "ž", with: "z")
            .replacingOccurrences(of: "š", with: "s")
            .replacingOccurrences(of: "č", with: "c")
            .replacingOccurrences(of: "ć", with: "c")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stationNameCache[normalizedName]
    }

    /// Updates the station name cache with SŽ station data
    /// Call this after fetching stations from SŽ API
    static func updateStationCache(with szStations: [SzStation]) {
        for station in szStations {
            let normalizedName = station.naziv.lowercased()
                .replacingOccurrences(of: "ž", with: "z")
                .replacingOccurrences(of: "š", with: "s")
                .replacingOccurrences(of: "č", with: "c")
                .replacingOccurrences(of: "ć", with: "c")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stationNameCache[normalizedName] = station.st
        }
    }

    /// Enriches a TrainConnection with data from SŽ API
    /// - Parameters:
    ///   - connection: The OEBB connection to enrich
    ///   - szData: Optional pre-fetched SŽ connection data
    /// - Returns: Enriched connection with SŽ platform/delay data where OEBB data is missing
    static func enrich(_ connection: TrainConnection, with szData: SzConnection?) -> TrainConnection {
        guard let szData, !szData.legs.isEmpty else { return connection }

        // Try to match the first leg to get platform/delay info
        guard let firstSzLeg = szData.legs.first else { return connection }

        // Enrich platform if missing from OEBB
        let enrichedPlatform = connection.platform ?? firstSzLeg.departure.platform

        // Enrich delay if missing or zero in OEBB
        let enrichedDelay = connection.delay > 0 ? connection.delay : (firstSzLeg.departure.delay ?? 0)

        // Determine status based on enriched delay
        let enrichedStatus: ConnectionStatus = if connection.status == .cancelled {
            .cancelled
        } else if enrichedDelay > 0 {
            .delayed
        } else {
            .onTime
        }

        // Enrich legs
        let enrichedLegs = enrichLegs(connection.legs, with: szData.legs)

        return TrainConnection(
            id: connection.id,
            lineNumber: connection.lineNumber,
            departureTime: connection.departureTime,
            arrivalTime: connection.arrivalTime,
            departureStation: connection.departureStation,
            arrivalStation: connection.arrivalStation,
            platform: enrichedPlatform,
            delay: enrichedDelay,
            status: enrichedStatus,
            transfers: connection.transfers,
            legs: enrichedLegs
        )
    }

    /// Enriches connection legs with SŽ data
    private static func enrichLegs(_ oebbLegs: [ConnectionLeg], with szLegs: [SzLeg]) -> [ConnectionLeg] {
        oebbLegs.enumerated().map { index, oebbLeg in
            // Try to find matching SŽ leg by index or train number
            let szLeg = szLegs.indices.contains(index) ? szLegs[index] : szLegs.first { matchesLeg(oebbLeg, szLeg: $0) }

            guard let szLeg else { return oebbLeg }

            // Enrich with SŽ data where OEBB is missing
            return ConnectionLeg(
                id: oebbLeg.id,
                from: oebbLeg.from,
                to: oebbLeg.to,
                departureTime: oebbLeg.departureTime,
                arrivalTime: oebbLeg.arrivalTime,
                platform: oebbLeg.platform ?? szLeg.departure.platform,
                lineNumber: oebbLeg.lineNumber,
                isWalking: oebbLeg.isWalking,
                duration: oebbLeg.duration,
                finalDestination: oebbLeg.finalDestination,
                platformChanged: oebbLeg.platformChanged,
                stopCount: oebbLeg.stopCount,
                delayMinutes: oebbLeg.delayMinutes ?? szLeg.departure.delay,
                intermediateStops: oebbLeg.intermediateStops
            )
        }
    }

    /// Checks if an OEBB leg matches an SŽ leg
    private static func matchesLeg(_ oebbLeg: ConnectionLeg, szLeg: SzLeg) -> Bool {
        // Match by train number
        let oebbTrainNumber = oebbLeg.lineNumber.components(separatedBy: .whitespaces).last ?? oebbLeg.lineNumber
        let szTrainNumber = szLeg.trainNumber

        if oebbTrainNumber.lowercased() == szTrainNumber.lowercased() {
            return true
        }

        // Match by departure time (within 5 minute tolerance)
        if let oebbDep = oebbLeg.departureTime {
            let timeDiff = abs(oebbDep.timeIntervalSince(szLeg.departure.time))
            if timeDiff < 300 { // 5 minutes
                return true
            }
        }

        return false
    }

    /// Converts an OEBB ESN station ID to SŽ station code
    static func szStationId(fromOebbEsn esn: Int) -> String? {
        stationMapping[esn]
    }

    /// Converts an OEBB ESN station ID to SŽ station code (string version)
    static func szStationId(fromOebbEsn esn: String) -> String? {
        guard let esnInt = Int(esn) else { return nil }
        return stationMapping[esnInt]
    }

    /// Finds the best matching SŽ connection for an OEBB connection
    static func findMatchingConnection(
        _ oebbConnection: TrainConnection,
        in szConnections: [SzConnection]
    ) -> SzConnection? {
        // First try to match by departure time
        let oebbDepartureTime = oebbConnection.departureTime

        // Find connections within 5 minute window
        let candidates = szConnections.filter { szConn in
            guard let firstLeg = szConn.legs.first else { return false }
            let timeDiff = abs(oebbDepartureTime.timeIntervalSince(firstLeg.departure.time))
            return timeDiff < 300 // 5 minutes
        }

        if candidates.count == 1 {
            return candidates.first
        }

        // If multiple candidates, try to match by train number
        if candidates.count > 1 {
            let oebbTrainNumber = oebbConnection.lineNumber.components(separatedBy: .whitespaces).last ?? oebbConnection
                .lineNumber

            return candidates.first { szConn in
                guard let firstLeg = szConn.legs.first else { return false }
                return firstLeg.trainNumber.lowercased() == oebbTrainNumber.lowercased()
            } ?? candidates.first
        }

        // Fallback: return first connection with matching train number
        return szConnections.first { szConn in
            guard let firstLeg = szConn.legs.first else { return false }
            let oebbTrainNumber = oebbConnection.lineNumber.components(separatedBy: .whitespaces).last ?? oebbConnection
                .lineNumber
            return firstLeg.trainNumber.lowercased() == oebbTrainNumber.lowercased()
        }
    }
}
