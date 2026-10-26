import Foundation

/// How Nimbus routes the player's controller when a game moves between the
/// iPad and the Apple TV. The session handoff itself is unaffected.
nonisolated enum ControllerMode: String, Codable, CaseIterable, Sendable {
    /// Local controller when playing here. After an iPad → Apple TV handoff the
    /// iPad relays its controller, and the TV drops the relay as soon as a
    /// controller connects to it directly over Bluetooth.
    case automatic
    /// Never relay: the controller must be paired to the device showing the game.
    case bluetoothDirect
    /// Always relay from the iPad, even if the TV has its own controller.
    case wifiRelay
    /// Like the relay, for a controller plugged into the iPad by cable. iPadOS
    /// does not tell apps whether a controller is wired or Bluetooth, so this is
    /// the same path as `wifiRelay`, kept separate so the choice is explicit.
    case usb

    static let defaultsKey = "controllerMode"

    /// The mode stored on this device, `automatic` when none is saved.
    static func load(from defaults: UserDefaults = .standard) -> ControllerMode {
        defaults.string(forKey: defaultsKey).flatMap(ControllerMode.init(rawValue:)) ?? .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The routing decisions, kept free of GameController and networking so they
/// can be tested directly.
nonisolated enum ControllerRoutingPolicy {
    /// iPad, at handoff time: should this device keep its controller and relay it?
    static func senderRelays(mode: ControllerMode, hasLocalController: Bool) -> Bool {
        guard hasLocalController else { return false }
        switch mode {
        case .automatic, .wifiRelay, .usb:
            return true
        case .bluetoothDirect:
            return false
        }
    }

    /// Apple TV, while receiving a relay: should relayed input reach the game?
    /// In automatic mode a controller connected directly to the TV wins, so the
    /// same player is never driven twice.
    static func receiverUsesRelay(mode: ControllerMode, tvHasDirectController: Bool) -> Bool {
        switch mode {
        case .automatic:
            !tvHasDirectController
        case .wifiRelay, .usb:
            true
        case .bluetoothDirect:
            false
        }
    }

    /// iPad, while relaying: how often to send when the TV says it is using a
    /// direct controller (keep-alive only) versus actively relaying.
    static func keepAliveInterval(relayInUse: Bool) -> UInt64 {
        relayInUse ? 50_000_000 : 1_000_000_000
    }
}

/// Rolling latency statistics in nanoseconds (median, P95, P99).
nonisolated struct LatencyStats: Equatable, Sendable {
    static let capacity = 512

    private(set) var samples: [UInt64] = []
    private var nextIndex = 0

    var count: Int {
        samples.count
    }

    mutating func add(_ nanoseconds: UInt64) {
        if samples.count < Self.capacity {
            samples.append(nanoseconds)
        } else {
            samples[nextIndex] = nanoseconds
        }
        nextIndex = (nextIndex + 1) % Self.capacity
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        nextIndex = 0
    }

    /// Nearest-rank percentile, nil without samples. `fraction` is 0...1.
    func percentile(_ fraction: Double) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    var median: UInt64? {
        percentile(0.5)
    }

    var p95: UInt64? {
        percentile(0.95)
    }

    var p99: UInt64? {
        percentile(0.99)
    }

    static func milliseconds(_ nanoseconds: UInt64?) -> String {
        guard let nanoseconds else { return "–" }
        return String(format: "%.1f ms", Double(nanoseconds) / 1_000_000)
    }
}
