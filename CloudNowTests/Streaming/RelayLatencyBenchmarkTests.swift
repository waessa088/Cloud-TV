@testable import CloudNow
import Foundation
import Network
import Testing

/// Measures the relay's own overhead end to end over the loopback interface:
/// UDP send → receiver decode → inbox → input-path notification → ack → UDP
/// back. Wi-Fi adds its own delay on real devices; this isolates the code.
@Suite("Relay latency benchmark", .serialized)
struct RelayLatencyBenchmarkTests {
    @Test("Loopback round trip of the relay stays well inside the budget")
    @MainActor
    func loopbackLatency() async throws {
        let receiver = RemoteGamepadReceiver()
        receiver.start(instanceName: "NimbusBench-\(UUID().uuidString.prefix(6))")
        defer { receiver.stop() }

        var port: UInt16?
        for _ in 0 ..< 100 {
            port = receiver.port
            if port != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let listeningPort = try #require(port)

        RemoteGamepadInbox.shared.beginSession(token: 77, mode: .wifiRelay)
        defer { RemoteGamepadInbox.shared.endSession() }

        let probe = RelayLoopbackProbe(port: listeningPort, token: 77)
        let stats = await probe.run(packets: 400)

        let median = LatencyStats.milliseconds(stats.median)
        let p95 = LatencyStats.milliseconds(stats.p95)
        let p99 = LatencyStats.milliseconds(stats.p99)
        print("RELAY_LOOPBACK_LATENCY one-way(rtt/2) samples=\(stats.count) median=\(median) p95=\(p95) p99=\(p99)")

        #expect(stats.count >= 50)
        // A generous bound for shared CI machines; real numbers are in the log.
        #expect((stats.p99 ?? .max) < 20_000_000)
    }
}

/// Sends relay packets at 1 kHz and times the acknowledgements.
private final nonisolated class RelayLoopbackProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "relay.bench", qos: .userInteractive)
    private let connection: NWConnection
    private let token: UInt64
    private var stats = LatencyStats()

    init(port: UInt16, token: UInt64) {
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        self.token = token
    }

    func run(packets: Int) async -> LatencyStats {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                connection.start(queue: queue)
                receive()
                send(sequence: 1, remaining: packets) {
                    self.queue.asyncAfter(deadline: .now() + 0.3) {
                        self.connection.cancel()
                        continuation.resume(returning: self.stats)
                    }
                }
            }
        }
    }

    private func send(sequence: UInt32, remaining: Int, done: @escaping @Sendable () -> Void) {
        guard remaining > 0 else {
            done()
            return
        }
        var state = RelayedGamepadState()
        state.leftStickX = Int16(truncatingIfNeeded: Int(sequence) * 97)
        let data = RelayedGamepadPacket.encode(
            state,
            token: token,
            sequence: sequence,
            sentAt: DispatchTime.now().uptimeNanoseconds
        )
        connection.send(content: data, completion: .idempotent)
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
            send(sequence: sequence + 1, remaining: remaining - 1, done: done)
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if let data, let ack = RelayAckPacket.decode(data), ack.token == token, now > ack.echoedSentAt {
                stats.add((now - ack.echoedSentAt) / 2)
            }
            if error == nil {
                receive()
            }
        }
    }
}
