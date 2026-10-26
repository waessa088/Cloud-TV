@testable import CloudNow
import Foundation
import Testing

@Suite("Smart controller handoff routing")
struct ControllerRoutingTests {
    @Test("The iPad relays only when the mode allows it and a controller is connected")
    func senderPolicy() {
        for mode in [ControllerMode.automatic, .wifiRelay, .usb] {
            #expect(ControllerRoutingPolicy.senderRelays(mode: mode, hasLocalController: true))
            #expect(!ControllerRoutingPolicy.senderRelays(mode: mode, hasLocalController: false))
        }
        #expect(!ControllerRoutingPolicy.senderRelays(mode: .bluetoothDirect, hasLocalController: true))
    }

    @Test("The TV prefers its own Bluetooth controller in automatic mode")
    func receiverPolicy() {
        #expect(ControllerRoutingPolicy.receiverUsesRelay(mode: .automatic, tvHasDirectController: false))
        #expect(!ControllerRoutingPolicy.receiverUsesRelay(mode: .automatic, tvHasDirectController: true))
        #expect(ControllerRoutingPolicy.receiverUsesRelay(mode: .wifiRelay, tvHasDirectController: true))
        #expect(ControllerRoutingPolicy.receiverUsesRelay(mode: .usb, tvHasDirectController: true))
        #expect(!ControllerRoutingPolicy.receiverUsesRelay(mode: .bluetoothDirect, tvHasDirectController: false))
    }

    @Test("A suspended relay only sends a slow keep-alive")
    func keepAlive() {
        #expect(ControllerRoutingPolicy.keepAliveInterval(relayInUse: true) == 50_000_000)
        #expect(ControllerRoutingPolicy.keepAliveInterval(relayInUse: false) == 1_000_000_000)
    }

    @Test("The mode persists and defaults to automatic")
    func modePersistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "ControllerRoutingTests.\(UUID().uuidString)"))
        #expect(ControllerMode.load(from: defaults) == .automatic)
        ControllerMode.usb.save(to: defaults)
        #expect(ControllerMode.load(from: defaults) == .usb)
        defaults.set("garbage", forKey: ControllerMode.defaultsKey)
        #expect(ControllerMode.load(from: defaults) == .automatic)
    }

    @Test("Latency percentiles use the nearest rank")
    func percentiles() {
        var stats = LatencyStats()
        #expect(stats.median == nil)
        for value in 1 ... 100 {
            stats.add(UInt64(value) * 1_000_000)
        }
        #expect(stats.count == 100)
        #expect(stats.median == 50_000_000)
        #expect(stats.p95 == 95_000_000)
        #expect(stats.p99 == 99_000_000)
        #expect(LatencyStats.milliseconds(stats.median) == "50.0 ms")
        #expect(LatencyStats.milliseconds(nil) == "–")
    }

    @Test("Latency statistics keep a rolling window")
    func rollingWindow() {
        var stats = LatencyStats()
        for _ in 0 ..< LatencyStats.capacity {
            stats.add(100)
        }
        for _ in 0 ..< LatencyStats.capacity {
            stats.add(7)
        }
        #expect(stats.count == LatencyStats.capacity)
        #expect(stats.p99 == 7)
        stats.reset()
        #expect(stats.count == 0)
    }

    @Test("Relayed menu buttons map to pause-menu commands")
    func menuCommands() {
        #expect(RelayMenuCommand(pressedButtons: 0x0004) == .previous)
        #expect(RelayMenuCommand(pressedButtons: 0x0001) == .previous)
        #expect(RelayMenuCommand(pressedButtons: 0x0008) == .next)
        #expect(RelayMenuCommand(pressedButtons: 0x0002) == .next)
        #expect(RelayMenuCommand(pressedButtons: 0x1000) == .select)
        #expect(RelayMenuCommand(pressedButtons: 0x2000) == .close)
        #expect(RelayMenuCommand(pressedButtons: 0) == nil)
        #expect(RelayMenuCommand(pressedButtons: 0x4000) == nil)
    }
}
