import Foundation

@MainActor
final class StationSearchService {
    private let transportService: TransportServiceProtocol

    init(transportService: TransportServiceProtocol = TransportService.shared) {
        self.transportService = transportService
    }

    func searchStations(_ query: String, transportType: TransportType) async -> [Station] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            var candidates = try await transportService.searchStations(matching: trimmed, transportType: transportType)

            // Add cached popular stations as a fallback pool when API results are sparse.
            if candidates.count < 8 {
                let cached = (try? await transportService.fetchStations(for: transportType)) ?? []
                candidates = mergeStations(primary: candidates, secondary: cached)
            }

            let ranked = rankStations(candidates, query: trimmed)
            return ranked
        } catch {
            if !(error is CancellationError) { /* logged silently */ }
            return []
        }
    }

    private func rankStations(_ stations: [Station], query: String) -> [Station] {
        let normalizedQuery = normalize(query)
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        let scored: [(station: Station, score: Int)] = stations.compactMap { station in
            let name = normalize(station.name)
            let words = name.split(separator: " ").map(String.init)
            guard let score = matchScore(name: name, words: words, query: normalizedQuery, queryTokens: queryTokens)
            else { return nil }
            return (station, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.station.name.count != rhs.station.name.count {
                    return lhs.station.name.count < rhs.station.name.count
                }
                return lhs.station.name.localizedCaseInsensitiveCompare(rhs.station.name) == .orderedAscending
            }
            .map(\.station)
    }

    private func matchScore(
        name: String,
        words: [String],
        query: String,
        queryTokens: [String]
    ) -> Int? {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 2 }
        if name.contains(query) { return 3 }

        guard !queryTokens.isEmpty else { return nil }

        let allTokensPrefix = queryTokens.allSatisfy { token in words.contains(where: { $0.hasPrefix(token) }) }
        if allTokensPrefix { return 4 }

        let allTokensContained = queryTokens.allSatisfy { token in name.contains(token) }
        if allTokensContained { return 5 }

        if queryTokens.contains(where: { token in words.contains(where: { $0.hasPrefix(token) }) }) { return 6 }
        if queryTokens.contains(where: { token in name.contains(token) }) { return 7 }

        return nil
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeStations(primary: [Station], secondary: [Station]) -> [Station] {
        var merged = primary
        var seen = Set(primary.map(\.id))
        for station in secondary where seen.insert(station.id).inserted {
            merged.append(station)
        }
        return merged
    }
}
