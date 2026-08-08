import Foundation
import Network

/// Reports whether the device currently has a usable network path.
///
/// A protocol because routing and tool availability both branch on it, and neither should need a real
/// radio to be tested (§54, §70).
protocol NetworkStatusProviding: Sendable {
    var isOnline: Bool { get async }
}

/// `NetworkStatusProviding` backed by `NWPathMonitor`.
///
/// Reachability is read from a cached path status rather than probed on demand: routing happens on
/// every turn, and blocking a turn on a network check would add latency to the on-device path that
/// does not need the network at all.
///
/// The initial value is `true` on purpose. Assuming online until told otherwise means a first request
/// made before the monitor's first callback is routed normally and fails with a real network error if
/// it must — which is a better outcome than pre-emptively refusing it and telling the user they are
/// offline when they are not.
actor NetworkMonitor: NetworkStatusProviding {

    private let monitor: NWPathMonitor
    private var cachedIsOnline: Bool
    private static let queue = DispatchQueue(label: "com.aura.network-monitor", qos: .utility)

    init() {
        monitor = NWPathMonitor()
        cachedIsOnline = true

        // Assigning the handler and starting the monitor touch only the `NWPathMonitor` instance, so
        // this is legal from a non-isolated actor initialiser. State updates hop onto the actor.
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.updateStatus(satisfied) }
        }
        monitor.start(queue: Self.queue)
    }

    deinit {
        monitor.cancel()
    }

    var isOnline: Bool { cachedIsOnline }

    private func updateStatus(_ isOnline: Bool) {
        guard cachedIsOnline != isOnline else { return }
        cachedIsOnline = isOnline
        AuraLog.app.info("Network path is now \(isOnline ? "satisfied" : "unsatisfied", privacy: .public)")
    }
}

/// A fixed network status, for tests and previews.
struct StubNetworkMonitor: NetworkStatusProviding {
    private let value: Bool

    init(isOnline: Bool = true) {
        self.value = isOnline
    }

    var isOnline: Bool { value }

    static let online = StubNetworkMonitor(isOnline: true)
    static let offline = StubNetworkMonitor(isOnline: false)
}
