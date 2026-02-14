import Foundation

@MainActor
final class StationSearchService {
    private let transportService: TransportServiceProtocol
    private let nearbyStationService: NearbyStationService

    init(
        transportService: TransportServiceProtocol = TransportService.shared,
        nearbyStationService: NearbyStationService
    ) {
        self.transportService = transportService
        self.nearbyStationService = nearbyStationService
    }

    func searchStations(_ query: String, transportType: TransportType) async -> [Station] {
        do {
            let results = try await transportService.searchStations(matching: query, transportType: transportType)
            let lowercased = query.lowercased()
            let filtered = results.filter {
                $0.name.lowercased().hasPrefix(lowercased) || $0.name.lowercased() == lowercased
            }
            nearbyStationService.updateDistances(for: filtered)
            return filtered
        } catch {
            if !(error is CancellationError) { /* logged silently */ }
            return []
        }
    }
}
