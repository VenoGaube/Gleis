import Foundation

struct Station: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let coordinate: Coordinate?
    let lines: [String]
    let countryCode: String?

    struct Coordinate: Codable, Equatable, Hashable {
        let latitude: Double
        let longitude: Double
    }

    init(
        id: String, name: String, coordinate: Coordinate?, lines: [String] = [],
        countryCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.lines = lines
        self.countryCode = countryCode
    }
}

extension Station {
    /// The name folded for comparison: no case or diacritics, "Hauptbahnhof" written as "hbf", single spaces.
    static func comparableName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0 == "hauptbahnhof" ? "hbf" : String($0) }
            .joined(separator: " ")
    }

    /// The name without a trailing bracketed part, so "Wien Hbf (Bahnsteige 3-12)" becomes "Wien Hbf".
    static func nameWithoutBrackets(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The city a station belongs to, so "Graz Hbf" and "Wien Hbf (U)" become "Graz" and "Wien".
    static func cityName(_ name: String) -> String {
        nameWithoutBrackets(name).replacingOccurrences(
            of: #"\s+(hbf|hauptbahnhof)\.?$"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
    }
}
