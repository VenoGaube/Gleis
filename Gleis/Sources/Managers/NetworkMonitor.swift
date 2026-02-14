import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    @Published private(set) var wasOffline = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let connected = path.status == .satisfied
                if !connected { self?.wasOffline = true }
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }

    func clearOfflineFlag() { wasOffline = false }

    deinit { monitor.cancel() }
}
