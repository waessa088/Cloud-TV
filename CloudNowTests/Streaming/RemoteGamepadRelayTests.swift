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

    @Test("F04-H1 A packet round-trips every field, including stick extremes")
    func packetRoundTrip() throws {
        let data = RelayedGamepadPacket.encode(sample, token: 0xDEAD_BEEF_0123_4567, sequence: 42)
        #expect(data.count == RelayedGamepadPacket.size)

        let decoded = try #require(RelayedGamepadPacket.decode(data))
        #expect(decoded.token == 0xDEAD_BEEF_0123_4567)
        #expect(decoded.sequence == 42)
        #expect(decoded.state == sample)
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

        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 99, sequence: 1)))
        #expect(inbox.current() == sample)
    }

    @Test("F04-N2 Packets with another token, or with no session, are ignored")
    func inboxRejectsStrangers() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })

        #expect(!inbox.accept(RelayedGamepadPacket.encode(sample, token: 99, sequence: 1)))
        inbox.beginSession(token: 99)
        #expect(!inbox.accept(RelayedGamepadPacket.encode(sample, token: 100, sequence: 1)))
        #expect(inbox.current() == nil)
    }

    @Test("F04-E1 Reordered or duplicated datagrams never overwrite newer state")
    func inboxDropsOldSequences() {
        let clock = ManualClock()
        let inbox = RemoteGamepadInbox(now: { clock.now })
        inbox.beginSession(token: 7)
        var newer = sample
        newer.buttons = 0x0001

        #expect(inbox.accept(RelayedGamepadPacket.encode(newer, token: 7, sequence: 10)))
        #expect(!inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 9)))
        #expect(!inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 10)))
        #expect(inbox.current() == newer)
        // Sequence wrap-around is still accepted.
        #expect(inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 11)))
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
        #expect(!inbox.accept(RelayedGamepadPacket.encode(sample, token: 7, sequence: 2)))
    }

    @Test("F04-H3 The handoff message carries the relay token and release flag")
    func handoffMessageRelayFields() throws {
        let game = TestGameFactory.make(id: "g", title: "Game")
        let withRelay = HandoffMessage(game: game, sessionId: "s", appId: nil, relayToken: 0xABCDEF)
        let decoded = try #require(HandoffMessage.decode(withRelay.encoded()))
        #expect(decoded.relayTokenValue == 0xABCDEF)
        #expect(!decoded.isRelease)

        let release = HandoffMessage(game: game, sessionId: "s", appId: nil, release: true)
        let decodedRelease = try #require(HandoffMessage.decode(release.encoded()))
        #expect(decodedRelease.isRelease)
        #expect(decodedRelease.relayTokenValue == nil)
    }
}
