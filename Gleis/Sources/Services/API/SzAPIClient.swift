import Foundation

// MARK: - SzAPIClient

/// API Client for Slovenske železnice (Slovenian Railways) SOAP API
/// Used to supplement OEBB data with Slovenian-specific information (platforms, delays)
actor SzAPIClient {
    static let shared = SzAPIClient()

    private let baseURL = URL(string: "http://91.209.49.139/webse/se.asmx")!
    private let namespace = "http://www.slo-zeleznice.si/"
    private let username = "zeljko"
    private let password = "joksimovic"
    private let urlSession: URLSession

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Ljubljana")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(urlSession: URLSession? = nil) {
        // Create session that allows insecure HTTP (the SŽ API doesn't support HTTPS)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = urlSession ?? URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch all stations from the Slovenian railway network
    func fetchStations() async throws -> [SzStation] {
        let soapBody = buildSOAPEnvelope(method: "Postaje", params: [:])
        let data = try await performSOAPRequest(body: soapBody, soapAction: "Postaje")
        return try SzSOAPParser.parseStations(from: data)
    }

    /// Search for journeys between two stations
    /// - Parameters:
    ///   - originId: Origin station ID (SŽ station code)
    ///   - destinationId: Destination station ID (SŽ station code)
    ///   - date: Travel date
    /// - Returns: Array of connections with train information
    func searchJourneys(originId: String, destinationId: String, date: Date) async throws -> [SzConnection] {
        let params: [String: String] = [
            "vs": originId,
            "iz": destinationId,
            "vi": "", // Via station (empty if not used)
            "da": dateFormatter.string(from: date)
        ]
        let soapBody = buildSOAPEnvelope(method: "Iskalnik_mob", params: params)
        let data = try await performSOAPRequest(body: soapBody, soapAction: "Iskalnik_mob")
        return try SzSOAPParser.parseJourneys(from: data)
    }

    /// Fetch stopovers for a specific train leg
    /// - Parameters:
    ///   - trainNumber: Train line identifier
    ///   - date: Travel date
    ///   - originId: Origin station ID
    ///   - destinationId: Destination station ID
    /// - Returns: Array of stopovers with arrival/departure times
    func fetchStopovers(
        trainNumber: String,
        date: Date,
        originId: String,
        destinationId: String
    ) async throws -> [SzStopover] {
        let params: [String: String] = [
            "vl": trainNumber,
            "da": dateFormatter.string(from: date),
            "p_OD": originId,
            "p_DO": destinationId
        ]
        let soapBody = buildSOAPEnvelope(method: "Postaje_vlaka", params: params)
        let data = try await performSOAPRequest(body: soapBody, soapAction: "Postaje_vlaka")
        return try SzSOAPParser.parseStopovers(from: data)
    }

    // MARK: - SOAP Helpers

    private func buildSOAPEnvelope(method: String, params: [String: String]) -> String {
        var paramsXML = """
            <username>\(username)</username>
            <password>\(password)</password>
        """

        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            paramsXML += "\n            <\(key)>\(escapeXML(value))</\(key)>"
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                       xmlns:xsd="http://www.w3.org/2001/XMLSchema"
                       xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
            <soap:Body>
                <\(method) xmlns="\(namespace)">
        \(paramsXML)
                </\(method)>
            </soap:Body>
        </soap:Envelope>
        """
    }

    private func performSOAPRequest(body: String, soapAction: String) async throws -> Data {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(namespace)\(soapAction)", forHTTPHeaderField: "SOAPAction")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SzAPIError.networkError("Invalid response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SzAPIError.httpError(httpResponse.statusCode)
        }

        return data
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - SzAPIError

enum SzAPIError: Error, LocalizedError {
    case networkError(String)
    case httpError(Int)
    case parsingError(String)

    var errorDescription: String? {
        switch self {
        case let .networkError(message): "SŽ Network Error: \(message)"
        case let .httpError(code): "SŽ HTTP Error: \(code)"
        case let .parsingError(message): "SŽ Parsing Error: \(message)"
        }
    }
}
