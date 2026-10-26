@testable import CloudNow
import Foundation
import Synchronization
import Testing

@Suite("Controller relay (iPad → Apple TV)")
struct RemoteGamepadRelayTests {
    private let sample = RelayedGamepadState(
        buttons: 0x1234,
        leftTrigger: 200,
        rightTrigger: 7,
        leftStickX: -32768,
        leftStickY: 32767,
        rightStickX: -1,
        rightStickY: 1,
        menuPresses: 3
    )

    /// A clock the test advances by hand.
    private final nonisolated class ManualClock: Sendable {
        private let value = Mutex<UInt64>(1_000_000_000)

        var now: UInt64 {
            value.withLock { $0 }
        }

        func advance(by nanoseconds: UInt64) {
            value.withLock { $0 += nanoseconds }
        }
    }

    @Test("F04-H1 A packet round-trips every field, including stick extremes and the clock")
    func packetRoundTrip() throws {
        let data = RelayedGamepadPacket.encode(
            sample,
            token: 0xDEAD_BEEF_0123_4567,
            sequence: 42,
            sentAt: 987_654_321_012
        )
        #expect(data.count == RelayedGamepadPacket.size)

        let decoded = try #require(RelayedGamepadPacket.decode(data))
        #expect(decoded.token == 0xDEAD_BEEF_0123_4567)
        #expect(decoded.sequence == 42)
        #expect(decoded.sentAt == 987_654_321_012)
        #expect(decoded.state == sample)
    }

    @Test("F04-H4 Every stick and trigger value survives the wire unchanged (no smoothing)")
    func fullPrecision() throws {
        for value in [Int16.min, -12345, -1, 0, 1, 777, Int16.max] {
            var state = sample
            state.leftStickX = value
            state.rightStickY = value
            state.leftTrigger = UInt8(truncatingIfNeeded: value)
            let decoded = try #require(RelayedGamepadPacket.decode(
                RelayedGamepadPacket.encode(state, token: 1, sequence: 1)
            ))
            #expect(decoded.state == state)
        }
    }

    @Test("F04-H5 An ack echoes the sender clock and the routing flags")
    func ackRoundTrip() throws {
        let flags = RelayAckPacket.flagRelayInUse | RelayAckPacket.flagDirectController
        let data = RelayAckPacket.encode(token: 9, sequence: 400, echoedSentAt: 123_456, flags: flags)
        #expect(data.count == RelayAckPacket.size)
        let ack = try #require(RelayAckPacket.decode(data))
        #expect(ack.token == 9)
        #expect(ack.sequence == 400)
        #expect(ack.echoedSentAt == 123_456)
        #expect(ack.relayInUse)
        #expect(ack.tvHasDirectController)
        // A state packet is never mistaken for an ack, nor the reverse.
        #expect(RelayAckPacket.decode(RelayedGamepadPacket.encode(sample, token: 9, sequence: 1)) == nil)
        #expect(RelayedGamepadPacket.decode(data) == nil)
    }

    @Test("F04-H6 Accepting a state reports what to acknowledge and notifies the input path")
    func inboxAcknowledgesAndNotifies() throws {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        let notified = ManualClock()
        inbox.setUpdateHandler { notified.advance(by: 1) }
        inbox.beginSession(token: 5)

        let accepted = try #require(inbox.accept(
            RelayedGamepadPacket.encode(sample, token: 5, sequence: 3, sentAt: 42)
        ))
        #expect(accepted.sequence == 3)
        #expect(accepted.sentAt == 42)
        #expect(accepted.flags == RelayAckPacket.flagRelayInUse)
        #expect(notified.now == 1_000_000_001)
    }

    @Test("F04-E4 In automatic mode a controller on the TV suspends the relay, no double input")
    func directControllerSuspendsRelay() throws {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        inbox.beginSession(token: 5, mode: .automatic)
        inbox.accept(RelayedGamepadPacket.encode(sample, token: 5, sequence: 1))
        #expect(inbox.current() == sample)

        inbox.setDirectControllerActive(true)
        #expect(inbox.current() == nil)
        let accepted = try #require(inbox.accept(RelayedGamepadPacket.encode(sample, token: 5, sequence: 2)))
        #expect(accepted.flags == RelayAckPacket.flagDirectController)

        // Forced relay keeps the relay even with a controller on the TV.
        inbox.beginSession(token: 6, mode: .wifiRelay, directControllerActive: true)
        inbox.accept(RelayedGamepadPacket.encode(sample, token: 6, sequence: 1))
        #expect(inbox.current() == sample)
    }

    @Test("F04-N1 Wrong size or magic is rejected")
    func rejectsMalformedPackets() {
        let data = RelayedGamepadPacket.encode(sample, token: 1, sequence: 1)
        #expect(RelayedGamepadPacket.decode(Data()) == nil)
        #expect(RelayedGamepadPacket.decode(data.dropLast()) == nil)

        var wrongMagic = data
        wrongMagic[0] = 0x00
        #expect(RelayedGamepadPacket.decode(wrongMagic) == nil)
    }

    @Test("F04-H2 The inbox exposes the latest state for the agreed token")
    func inboxAcceptsTokenHolder() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        inbox.beginSession(token: 99)

        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 99, sequence: 1)) != nil)
        #expect(inbox.current() == sample)
    }

    @Test("F04-N2 Packets with another token, or with no session, are ignored")
    func inboxRejectsStrangers() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })

        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 99, sequence: 1)) == nil)
        inbox.beginSession(token: 99)
        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 100, sequence: 1)) == nil)
        #expect(inbox.current() == nil)
    }

    @Test("F04-E1 Reordered or duplicated datagrams never overwrite newer state")
    func inboxDropsOldSequences() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        inbox.beginSession(token: 7)
        var newer = sample
        newer.buttons = 0x0001

        #expect(inbox.accept(RelayedGamepadPacket.encode(newer, token: 7, sequence: 10)) != nil)
        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 9)) == nil)
        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 10)) == nil)
        #expect(inbox.current() == newer)
        // Sequence wrap-around is still accepted.
        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 11)) != nil)
    }

    @Test("F04-E2 A silent relay reads as absent so no button stays held")
    func inboxGoesStale() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        inbox.beginSession(token: 7)
        inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 1))

        clock.advance(by: RemoteGamepadInbox.staleAfterNanoseconds)
        #expect(inbox.current() == sample)
        clock.advance(by: 1)
        #expect(inbox.current() == nil)
    }

    @Test("F04-E3 Ending the session forgets state and token")
    func inboxEndSession() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        inbox.beginSession(token: 7)
        inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 1))

        inbox.endSession()
        #expect(!inbox.isActive)
        #expect(inbox.current() == nil)
        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 2)) == nil)
    }

    @Test("F04-H3 The handoff message carries the relay token, controller mode and release flag")
    func handoffMessageRelayFields() throws {
        let game = TestGameFactory.make(id: "g", title: "Game")
        let withRelay = HandoffMessage(
            game: game,
            sessionId: "s",
            appId: nil,
            relayToken: 0xABCDEF,
            controllerMode: .usb
        )
        let decoded = try #require(HandoffMessage.decode(withRelay.encoded()))
        #expect(decoded.relayTokenValue == 0xABCDEF)
        #expect(decoded.controllerModeValue == .usb)
        #expect(!decoded.isRelease)

        // Messages from an older build without a mode default to automatic.
        let legacy = HandoffMessage(game: game, sessionId: "s", appId: nil)
        #expect(try HandoffMessage.decode(legacy.encoded())?.controllerModeValue == .automatic)

        let release = HandoffMessage(game: game, sessionId: "s", appId: nil, release: true)
        let decodedRelease = try #require(HandoffMessage.decode(release.encoded()))
        #expect(decodedRelease.isRelease)
        #expect(decodedRelease.relayTokenValue == nil)
    }
}
