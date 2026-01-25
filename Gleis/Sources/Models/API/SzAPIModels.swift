import Foundation

// MARK: - SzStation

struct SzStation: Decodable {
    let st: String // Station ID
    let naziv: String // Station name
}

// MARK: - SzJourneyResponse

struct SzJourneyResponse {
    let connections: [SzConnection]
}

// MARK: - SzConnection

struct SzConnection {
    let legs: [SzLeg]
    let price: SzPrice?
}

// MARK: - SzLeg

struct SzLeg {
    let trainNumber: String // vlak
    let trainType: String // vrsta
    let departure: SzStopTime
    let arrival: SzStopTime
    let allowBicycle: Bool?
    let hasWifi: Bool?
}

// MARK: - SzStopTime

struct SzStopTime {
    let stationId: String
    let stationName: String
    let time: Date
    let platform: String?
    let delay: Int? // Delay in minutes
}

// MARK: - SzPrice

struct SzPrice {
    let amount: Double
    let currency: String
}

// MARK: - SzStopover

struct SzStopover {
    let stationId: String
    let stationName: String
    let arrivalTime: Date?
    let departureTime: Date?
    let platform: String?
    let arrivalDelay: Int?
    let departureDelay: Int?
}

// MARK: - SzSOAPParser

enum SzSOAPParser {
    /// Parse stations from SOAP response
    static func parseStations(from xmlData: Data) throws -> [SzStation] {
        let parser = SzXMLParser(data: xmlData)
        return try parser.parseStations()
    }

    /// Parse journeys from SOAP response
    static func parseJourneys(from xmlData: Data) throws -> [SzConnection] {
        let parser = SzXMLParser(data: xmlData)
        return try parser.parseJourneys()
    }

    /// Parse stopovers from SOAP response
    static func parseStopovers(from xmlData: Data) throws -> [SzStopover] {
        let parser = SzXMLParser(data: xmlData)
        return try parser.parseStopovers()
    }
}

// MARK: - SzXMLParser

final class SzXMLParser: NSObject, XMLParserDelegate {
    private let xmlParser: XMLParser
    private var currentElement = ""
    private var currentText = ""

    // Station parsing
    private var stations: [SzStation] = []
    private var currentStationId = ""
    private var currentStationName = ""
    private var inStation = false

    // Journey parsing
    private var connections: [SzConnection] = []
    private var currentLegs: [SzLeg] = []
    private var inConnection = false
    private var inLeg = false

    // Current leg data
    private var legTrainNumber = ""
    private var legTrainType = ""
    private var legDepartureStation = ""
    private var legDepartureName = ""
    private var legDepartureTime = ""
    private var legDeparturePlatform: String?
    private var legArrivalStation = ""
    private var legArrivalName = ""
    private var legArrivalTime = ""
    private var legArrivalPlatform: String?
    private var legAllowBicycle: Bool?
    private var legHasWifi: Bool?

    // Stopover parsing
    private var stopovers: [SzStopover] = []
    private var inStopover = false
    private var stopoverStationId = ""
    private var stopoverStationName = ""
    private var stopoverArrival = ""
    private var stopoverDeparture = ""
    private var baseDate: Date?

    // Price
    private var currentPrice: Double?

    private var parseError: Error?

    init(data: Data) {
        self.xmlParser = XMLParser(data: data)
        super.init()
        xmlParser.delegate = self
    }

    func parseStations() throws -> [SzStation] {
        stations = []
        xmlParser.parse()
        if let error = parseError { throw error }
        return stations
    }

    func parseJourneys() throws -> [SzConnection] {
        connections = []
        xmlParser.parse()
        if let error = parseError { throw error }
        return connections
    }

    func parseStopovers() throws -> [SzStopover] {
        stopovers = []
        xmlParser.parse()
        if let error = parseError { throw error }
        return stopovers
    }

    // MARK: - XMLParserDelegate

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes _: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""

        switch currentElement {
        case "postaja":
            inStation = true
            currentStationId = ""
            currentStationName = ""
        case "connection":
            inConnection = true
            currentLegs = []
            currentPrice = nil
        case "vlak", "train":
            inLeg = true
            resetLegData()
        case "postanek", "stop":
            inStopover = true
            stopoverStationId = ""
            stopoverStationName = ""
            stopoverArrival = ""
            stopoverDeparture = ""
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        let element = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Station parsing
        if inStation {
            switch element {
            case "st": currentStationId = text
            case "naziv": currentStationName = text
            case "postaja":
                if !currentStationId.isEmpty {
                    stations.append(SzStation(st: currentStationId, naziv: currentStationName))
                }
                inStation = false
            default: break
            }
        }

        // Leg parsing
        if inLeg {
            switch element {
            case "stevilka": legTrainNumber = text
            case "vrsta", "tip": legTrainType = text
            case "odhodpostaja", "odhod_postaja": legDepartureStation = text
            case "odhodime", "odhod_ime": legDepartureName = text
            case "odhod": legDepartureTime = text
            case "odhodperon", "odhod_peron": legDeparturePlatform = text.isEmpty ? nil : text
            case "prihodpostaja", "prihod_postaja": legArrivalStation = text
            case "prihodime", "prihod_ime": legArrivalName = text
            case "prihod": legArrivalTime = text
            case "prihodperon", "prihod_peron": legArrivalPlatform = text.isEmpty ? nil : text
            case "kolo", "bicycle": legAllowBicycle = text == "1" || text.lowercased() == "true"
            case "wifi": legHasWifi = text == "1" || text.lowercased() == "true"
            case "vlak", "train":
                // "vlak" can be both a container element and contain the train number
                if !text.isEmpty { legTrainNumber = text }
                if let leg = createLeg() {
                    currentLegs.append(leg)
                }
                inLeg = false
            default: break
            }
        }

        // Connection end
        if element == "connection" && inConnection {
            let price = currentPrice.map { SzPrice(amount: $0, currency: "EUR") }
            connections.append(SzConnection(legs: currentLegs, price: price))
            inConnection = false
        }

        // Price
        if element == "cena" || element == "price" {
            currentPrice = Double(text)
        }

        // Stopover parsing
        if inStopover {
            switch element {
            case "st", "id": stopoverStationId = text
            case "naziv", "ime", "name": stopoverStationName = text
            case "prihod", "arrival": stopoverArrival = text
            case "odhod", "departure": stopoverDeparture = text
            case "postanek", "stop":
                if let stopover = createStopover() {
                    stopovers.append(stopover)
                }
                inStopover = false
            default: break
            }
        }

        // Base date for stopovers
        if element == "datum" {
            baseDate = parseDate(text, format: "yyyy-MM-dd")
        }

        currentText = ""
    }

    func parser(_: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    // MARK: - Helpers

    private func resetLegData() {
        legTrainNumber = ""
        legTrainType = ""
        legDepartureStation = ""
        legDepartureName = ""
        legDepartureTime = ""
        legDeparturePlatform = nil
        legArrivalStation = ""
        legArrivalName = ""
        legArrivalTime = ""
        legArrivalPlatform = nil
        legAllowBicycle = nil
        legHasWifi = nil
    }

    private func createLeg() -> SzLeg? {
        guard !legTrainNumber.isEmpty else { return nil }

        let depTime = parseTime(legDepartureTime) ?? Date()
        let arrTime = parseTime(legArrivalTime) ?? depTime

        return SzLeg(
            trainNumber: legTrainNumber,
            trainType: legTrainType,
            departure: SzStopTime(
                stationId: legDepartureStation,
                stationName: legDepartureName,
                time: depTime,
                platform: legDeparturePlatform,
                delay: nil
            ),
            arrival: SzStopTime(
                stationId: legArrivalStation,
                stationName: legArrivalName,
                time: arrTime,
                platform: legArrivalPlatform,
                delay: nil
            ),
            allowBicycle: legAllowBicycle,
            hasWifi: legHasWifi
        )
    }

    private func createStopover() -> SzStopover? {
        guard !stopoverStationName.isEmpty else { return nil }

        return SzStopover(
            stationId: stopoverStationId,
            stationName: stopoverStationName,
            arrivalTime: parseTime(stopoverArrival),
            departureTime: parseTime(stopoverDeparture),
            platform: nil,
            arrivalDelay: nil,
            departureDelay: nil
        )
    }

    private func parseTime(_ timeString: String) -> Date? {
        // Try various time formats used by SŽ
        let formats = ["HH:mm", "HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Ljubljana")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: timeString) {
                // If only time, combine with base date or today
                if format == "HH:mm" || format == "HH:mm:ss" {
                    let calendar = Calendar.current
                    let base = baseDate ?? Date()
                    var components = calendar.dateComponents([.year, .month, .day], from: base)
                    let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: date)
                    components.hour = timeComponents.hour
                    components.minute = timeComponents.minute
                    components.second = timeComponents.second
                    return calendar.date(from: components)
                }
                return date
            }
        }
        return nil
    }

    private func parseDate(_ dateString: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Ljubljana")
        formatter.dateFormat = format
        return formatter.date(from: dateString)
    }
}
