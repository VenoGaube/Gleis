import Foundation

// MARK: - OebbAuthSession

struct OebbAuthSession: Codable {
    let userId: String
    let accessToken: String
    let sessionId: String
    let supportId: String
    let channel: String
    let cookie: String?
    let expiresAt: Date
    let createdAt: Date

    var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - OebbAuthResponse

struct OebbAuthResponse: Decodable {
    let accessToken: String
    let sessionId: String
    let supportId: String
    let channel: String?
    let sessionTimeout: Int?
    let userId: String?
}

// MARK: - OebbStation

struct OebbStation: Decodable {
    let number: Int
    let longitude: Int
    let latitude: Int
    let name: String?
    let meta: String?
}

// MARK: - OebbStationRef

struct OebbStationRef {
    let number: Int
    let latitude: Int
    let longitude: Int
    let name: String
}

// MARK: - OebbTimetableResponse

struct OebbTimetableResponse: Decodable {
    let connections: [OebbConnection]

    enum CodingKeys: String, CodingKey { case connections }

    init(connections: [OebbConnection]) {
        self.connections = connections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connections = (try? container.decodeIfPresent([OebbConnection].self, forKey: .connections)) ?? []
    }
}

// MARK: - OebbConnection

struct OebbConnection: Decodable {
    let id: String
    let from: OebbConnectionStop
    let to: OebbConnectionStop
    let sections: [OebbSection]?
    let switches: Int?
    let duration: Int?

    enum CodingKeys: String, CodingKey { case id, from, to, sections, switches, duration }

    init(
        id: String,
        from: OebbConnectionStop,
        to: OebbConnectionStop,
        sections: [OebbSection]?,
        switches: Int?,
        duration: Int?
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.sections = sections
        self.switches = switches
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        from = try container.decode(OebbConnectionStop.self, forKey: .from)
        to = try container.decode(OebbConnectionStop.self, forKey: .to)
        sections = try? container.decodeIfPresent([OebbSection].self, forKey: .sections)
        switches = OebbDecoding.intIfPresent(container, forKey: .switches)
        duration = OebbDecoding.intIfPresent(container, forKey: .duration)
    }
}

// MARK: - OebbSection

struct OebbSection: Decodable {
    let from: OebbConnectionStop
    let to: OebbConnectionStop
    let duration: Int?
    let category: OebbCategory?
    let type: String?
    let hasRealtime: Bool?
    let stops: [OebbConnectionStop]?

    enum CodingKeys: String, CodingKey { case from, to, duration, category, type, hasRealtime, stops }

    init(
        from: OebbConnectionStop,
        to: OebbConnectionStop,
        duration: Int?,
        category: OebbCategory?,
        type: String?,
        hasRealtime: Bool?,
        stops: [OebbConnectionStop]?
    ) {
        self.from = from
        self.to = to
        self.duration = duration
        self.category = category
        self.type = type
        self.hasRealtime = hasRealtime
        self.stops = stops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(OebbConnectionStop.self, forKey: .from)
        to = try container.decode(OebbConnectionStop.self, forKey: .to)
        duration = OebbDecoding.intIfPresent(container, forKey: .duration)
        category = try container.decodeIfPresent(OebbCategory.self, forKey: .category)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        hasRealtime = OebbDecoding.boolIfPresent(container, forKey: .hasRealtime)
        stops = try? container.decodeIfPresent([OebbConnectionStop].self, forKey: .stops)
    }

    var stopCount: Int? {
        if let stops {
            guard !stops.isEmpty else { return 0 }

            // Most OEBB stop lists include origin + destination. Some payload variants only include
            // intermediate stops, so only subtract endpoints when they actually match this section.
            let fromName = normalizedStationName(from.name)
            let toName = normalizedStationName(to.name)
            let firstName = normalizedStationName(stops.first?.name)
            let lastName = normalizedStationName(stops.last?.name)
            let firstEsn = stops.first?.esn
            let lastEsn = stops.last?.esn
            let matchesByName = firstName == fromName && lastName == toName
            let matchesByEsn = from.esn != nil && to.esn != nil && firstEsn == from.esn && lastEsn == to.esn
            let includesEndpoints = (matchesByName || matchesByEsn) && stops.count >= 2

            return includesEndpoints ? max(stops.count - 2, 0) : stops.count
        }

        guard let type else { return nil }
        let lowered = type.lowercased()
        guard lowered.contains("halt") || lowered.contains("stop") else { return nil }

        for token in type.split(whereSeparator: { !$0.isNumber }) {
            if let value = Int(token) { return value }
        }
        return nil
    }

    private func normalizedStationName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).filter {
            $0.isLetter || $0.isNumber
        }
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - OebbCategory

struct OebbCategory: Decodable {
    let name: String?
    let number: String?
    let direction: String?
    let shortName: String?
    let displayName: String?
    let longName: [String: String]?
    let backgroundColor: String?
    let fontColor: String?
    let barColor: String?
    let backgroundColorDisabled: String?
    let fontColorDisabled: String?
    let barColorDisabled: String?
    let journeyPreviewIconColor: String?
    let ubahn: Bool?
    let sbahn: Bool?
    let train: Bool?

    init(
        name: String?,
        number: String?,
        direction: String? = nil,
        shortName: String?,
        displayName: String?,
        longName: [String: String]? = nil,
        backgroundColor: String? = nil,
        fontColor: String? = nil,
        barColor: String? = nil,
        backgroundColorDisabled: String? = nil,
        fontColorDisabled: String? = nil,
        barColorDisabled: String? = nil,
        journeyPreviewIconColor: String? = nil,
        ubahn: Bool? = nil,
        sbahn: Bool? = nil,
        train: Bool? = nil
    ) {
        self.name = name
        self.number = number
        self.direction = direction
        self.shortName = shortName
        self.displayName = displayName
        self.longName = longName
        self.backgroundColor = backgroundColor
        self.fontColor = fontColor
        self.barColor = barColor
        self.backgroundColorDisabled = backgroundColorDisabled
        self.fontColorDisabled = fontColorDisabled
        self.barColorDisabled = barColorDisabled
        self.journeyPreviewIconColor = journeyPreviewIconColor
        self.ubahn = ubahn
        self.sbahn = sbahn
        self.train = train
    }

    var lineColors: TrainLineColors? {
        let resolved = TrainLineColors(
            backgroundHex: backgroundColor ?? backgroundColorDisabled,
            foregroundHex: fontColor ?? fontColorDisabled,
            accentHex: barColor ?? journeyPreviewIconColor ?? barColorDisabled
        )
        return resolved.isEmpty ? nil : resolved
    }
}

// MARK: - OebbConnectionStop

struct OebbConnectionStop: Decodable {
    let name: String?
    let esn: Int?
    let departure: String?
    let arrival: String?
    let departureRealtime: String?
    let arrivalRealtime: String?
    let departureDelay: Int?
    let arrivalDelay: Int?
    let departurePlatform: String?
    let arrivalPlatform: String?
    let departurePlatformDeviation: String?
    let arrivalPlatformDeviation: String?
    let cancelled: Bool?

    enum CodingKeys: String, CodingKey {
        case name, esn, departure, arrival, departureRealtime, arrivalRealtime
        case departureDelay, arrivalDelay, departurePlatform, arrivalPlatform
        case departurePlatformDeviation, arrivalPlatformDeviation, cancelled
    }

    init(
        name: String?,
        esn: Int?,
        departure: String?,
        arrival: String?,
        departureRealtime: String? = nil,
        arrivalRealtime: String? = nil,
        departureDelay: Int? = nil,
        arrivalDelay: Int? = nil,
        departurePlatform: String? = nil,
        arrivalPlatform: String? = nil,
        departurePlatformDeviation: String? = nil,
        arrivalPlatformDeviation: String? = nil,
        cancelled: Bool? = nil
    ) {
        self.name = name
        self.esn = esn
        self.departure = departure
        self.arrival = arrival
        self.departureRealtime = departureRealtime
        self.arrivalRealtime = arrivalRealtime
        self.departureDelay = departureDelay
        self.arrivalDelay = arrivalDelay
        self.departurePlatform = departurePlatform
        self.arrivalPlatform = arrivalPlatform
        self.departurePlatformDeviation = departurePlatformDeviation
        self.arrivalPlatformDeviation = arrivalPlatformDeviation
        self.cancelled = cancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        esn = OebbDecoding.intIfPresent(container, forKey: .esn)
        departure = try container.decodeIfPresent(String.self, forKey: .departure)
        arrival = try container.decodeIfPresent(String.self, forKey: .arrival)
        departureRealtime = try container.decodeIfPresent(String.self, forKey: .departureRealtime)
        arrivalRealtime = try container.decodeIfPresent(String.self, forKey: .arrivalRealtime)
        departureDelay = OebbDecoding.intIfPresent(container, forKey: .departureDelay)
        arrivalDelay = OebbDecoding.intIfPresent(container, forKey: .arrivalDelay)
        departurePlatform = try container.decodeIfPresent(String.self, forKey: .departurePlatform)
        arrivalPlatform = try container.decodeIfPresent(String.self, forKey: .arrivalPlatform)
        departurePlatformDeviation = try container.decodeIfPresent(
            String.self, forKey: .departurePlatformDeviation
        )
        arrivalPlatformDeviation = try container.decodeIfPresent(String.self, forKey: .arrivalPlatformDeviation)
        cancelled = OebbDecoding.boolIfPresent(container, forKey: .cancelled)
    }
}

// MARK: - OebbConnectionDetailResponse

struct OebbConnectionDetailResponse: Decodable {
    let sections: [OebbConnectionDetailSection]

    enum CodingKeys: String, CodingKey { case sections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = (try? container.decodeIfPresent([OebbConnectionDetailSection].self, forKey: .sections)) ?? []
    }
}

struct OebbConnectionDetailSection: Decodable {
    let index: Int?
    let type: String?
    let from: OebbConnectionDetailStop?
    let to: OebbConnectionDetailStop?
    let intermediatePoints: [OebbConnectionDetailIntermediatePoint]
    let ride: OebbConnectionDetailRide?

    enum CodingKeys: String, CodingKey { case index, type, from, to, intermediatePoints, ride }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = OebbDecoding.intIfPresent(container, forKey: .index)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        from = try container.decodeIfPresent(OebbConnectionDetailStop.self, forKey: .from)
        to = try container.decodeIfPresent(OebbConnectionDetailStop.self, forKey: .to)
        intermediatePoints = (try? container.decodeIfPresent(
            [OebbConnectionDetailIntermediatePoint].self, forKey: .intermediatePoints
        )) ?? []
        ride = try container.decodeIfPresent(OebbConnectionDetailRide.self, forKey: .ride)
    }
}

struct OebbConnectionDetailRide: Decodable {
    let shortName: String?
    let name: String?
    let number: String?
}

struct OebbConnectionDetailStop: Decodable {
    let name: String?
    let departure: String?
    let arrival: String?
    let departurePlatform: String?
    let arrivalPlatform: String?
    let realtimeInformation: OebbConnectionDetailRealtimeInformation?
}

struct OebbConnectionDetailIntermediatePoint: Decodable {
    let name: String?
    let departure: String?
    let arrival: String?
    let realtimeInformation: OebbConnectionDetailRealtimeInformation?
}

struct OebbConnectionDetailRealtimeInformation: Decodable {
    let departure: String?
    let arrival: String?
    let departurePlatform: String?
    let arrivalPlatform: String?
}

// MARK: - OebbGateResponse

struct OebbGateResponse: Decodable {
    let svcResL: [OebbGateServiceResult]?
    let err: String?
}

struct OebbGateServiceResult: Decodable {
    let meth: String?
    let res: OebbGateServicePayload?
    let err: String?
}

struct OebbGateServicePayload: Decodable {
    let locL: [OebbGateLocation]?
    let common: OebbGateTripCommon?
    let outConL: [OebbGateTripConnection]?

    enum CodingKeys: String, CodingKey { case locL, common, outConL }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locL = OebbDecoding.lossyArrayIfPresent(container, forKey: .locL)
        common = try? container.decodeIfPresent(OebbGateTripCommon.self, forKey: .common)
        outConL = OebbDecoding.lossyArrayIfPresent(container, forKey: .outConL)
    }
}

struct OebbGateLocation: Decodable {
    let extId: String?
    let name: String?
    let crd: OebbGateCoordinate?
    let dist: Int?
    let dur: Int?
    let countryCodeL: [String]?
}

struct OebbGateCoordinate: Decodable {
    let x: Int?
    let y: Int?
}

struct OebbGateTripCommon: Decodable {
    let locL: [OebbGateLocation]?
    let prodL: [OebbGateTripProduct]?
    let icoL: [OebbGateTripIcon]?

    enum CodingKeys: String, CodingKey { case locL, prodL, icoL }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locL = OebbDecoding.lossyArrayIfPresent(container, forKey: .locL)
        prodL = OebbDecoding.lossyArrayIfPresent(container, forKey: .prodL)
        icoL = OebbDecoding.lossyArrayIfPresent(container, forKey: .icoL)
    }
}

struct OebbGateTripConnection: Decodable {
    let cid: String?
    let cksum: String?
    let dep: OebbGateTripStopRef?
    let arr: OebbGateTripStopRef?
    let secL: [OebbGateTripSection]?
    let chg: Int?
    let durS: String?
    let date: String?

    enum CodingKeys: String, CodingKey { case cid, cksum, dep, arr, secL, chg, durS, date }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try? container.decodeIfPresent(String.self, forKey: .cid)
        cksum = try? container.decodeIfPresent(String.self, forKey: .cksum)
        dep = try? container.decodeIfPresent(OebbGateTripStopRef.self, forKey: .dep)
        arr = try? container.decodeIfPresent(OebbGateTripStopRef.self, forKey: .arr)
        secL = OebbDecoding.lossyArrayIfPresent(container, forKey: .secL)
        chg = OebbDecoding.intIfPresent(container, forKey: .chg)
        durS = try? container.decodeIfPresent(String.self, forKey: .durS)
        date = try? container.decodeIfPresent(String.self, forKey: .date)
    }
}

struct OebbGateTripSection: Decodable {
    let type: String?
    let dep: OebbGateTripStopRef?
    let arr: OebbGateTripStopRef?
    let jny: OebbGateTripJourney?

    enum CodingKeys: String, CodingKey { case type, dep, arr, jny }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        dep = try? container.decodeIfPresent(OebbGateTripStopRef.self, forKey: .dep)
        arr = try? container.decodeIfPresent(OebbGateTripStopRef.self, forKey: .arr)
        jny = try? container.decodeIfPresent(OebbGateTripJourney.self, forKey: .jny)
    }
}

struct OebbGateTripJourney: Decodable {
    let stopL: [OebbGateTripStopRef]?
    let prodL: [OebbGateTripProductRef]?
    let dirTxt: String?
    let durS: String?
    let date: String?

    enum CodingKeys: String, CodingKey { case stopL, prodL, dirTxt, durS, date }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stopL = OebbDecoding.lossyArrayIfPresent(container, forKey: .stopL)
        prodL = OebbDecoding.lossyArrayIfPresent(container, forKey: .prodL)
        dirTxt = try? container.decodeIfPresent(String.self, forKey: .dirTxt)
        durS = try? container.decodeIfPresent(String.self, forKey: .durS)
        date = try? container.decodeIfPresent(String.self, forKey: .date)
    }
}

struct OebbGateTripProductRef: Decodable {
    let prodX: Int?
    let fIdx: Int?
    let tIdx: Int?

    enum CodingKeys: String, CodingKey { case prodX, fIdx, tIdx }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prodX = OebbDecoding.intIfPresent(container, forKey: .prodX)
        fIdx = OebbDecoding.intIfPresent(container, forKey: .fIdx)
        tIdx = OebbDecoding.intIfPresent(container, forKey: .tIdx)
    }
}

struct OebbGateTripStopRef: Decodable {
    let locX: Int?
    let idx: Int?
    let dTimeS: String?
    let aTimeS: String?
    let dPltfS: OebbGateTextValue?
    let aPltfS: OebbGateTextValue?
    let dProdX: Int?
    let aProdX: Int?
    let dTZOffset: Int?
    let aTZOffset: Int?

    enum CodingKeys: String, CodingKey {
        case locX, idx, dTimeS, aTimeS, dPltfS, aPltfS, dProdX, aProdX, dTZOffset, aTZOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locX = OebbDecoding.intIfPresent(container, forKey: .locX)
        idx = OebbDecoding.intIfPresent(container, forKey: .idx)
        dTimeS = try? container.decodeIfPresent(String.self, forKey: .dTimeS)
        aTimeS = try? container.decodeIfPresent(String.self, forKey: .aTimeS)
        dPltfS = try? container.decodeIfPresent(OebbGateTextValue.self, forKey: .dPltfS)
        aPltfS = try? container.decodeIfPresent(OebbGateTextValue.self, forKey: .aPltfS)
        dProdX = OebbDecoding.intIfPresent(container, forKey: .dProdX)
        aProdX = OebbDecoding.intIfPresent(container, forKey: .aProdX)
        dTZOffset = OebbDecoding.intIfPresent(container, forKey: .dTZOffset)
        aTZOffset = OebbDecoding.intIfPresent(container, forKey: .aTZOffset)
    }
}

struct OebbGateTextValue: Decodable {
    let txt: String?
    let type: String?
}

struct OebbGateTripProduct: Decodable {
    let name: String?
    let nameS: String?
    let number: String?
    let prodCtx: OebbGateTripProductContext?
    let icoX: Int?

    enum CodingKeys: String, CodingKey { case name, nameS, number, prodCtx, icoX }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        nameS = try? container.decodeIfPresent(String.self, forKey: .nameS)
        number = try? container.decodeIfPresent(String.self, forKey: .number)
        prodCtx = try? container.decodeIfPresent(OebbGateTripProductContext.self, forKey: .prodCtx)
        icoX = OebbDecoding.intIfPresent(container, forKey: .icoX)
    }
}

struct OebbGateTripProductContext: Decodable {
    let catIn: String?
    let catOut: String?
    let catOutL: String?
    let catOutS: String?
    let num: String?
    let name: String?
}

struct OebbGateTripIcon: Decodable {
    let bg: OebbGateTripRGBColor?
    let fg: OebbGateTripRGBColor?
}

struct OebbGateTripRGBColor: Decodable {
    let r: Int?
    let g: Int?
    let b: Int?
}

struct OebbNearbyLocation {
    let id: String
    let name: String
    let latitude: Int?
    let longitude: Int?
    let distanceMeters: Int?
    let durationSeconds: Int?
    let countryCode: String?
}

// MARK: - OebbDecoding

enum OebbDecoding {
    private struct FailableDecodable<Base: Decodable>: Decodable {
        let base: Base?

        init(from decoder: Decoder) throws {
            base = try? Base(from: decoder)
        }
    }

    static func intIfPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func boolIfPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let intValue = intIfPresent(container, forKey: key) { return intValue != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "y", "1"].contains(trimmed) { return true }
            if ["false", "no", "n", "0"].contains(trimmed) { return false }
        }
        return nil
    }

    static func lossyArrayIfPresent<K: CodingKey, T: Decodable>(
        _ container: KeyedDecodingContainer<K>, forKey key: K
    ) -> [T]? {
        if let values = try? container.decodeIfPresent([T].self, forKey: key) { return values }
        if let wrapped = try? container.decodeIfPresent([FailableDecodable<T>].self, forKey: key) {
            return wrapped.compactMap(\.base)
        }
        return nil
    }
}
