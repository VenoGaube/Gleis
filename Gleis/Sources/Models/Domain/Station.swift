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
