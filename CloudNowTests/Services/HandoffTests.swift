@testable import CloudNow
import Foundation
import Testing

@Suite("iPad ↔ Apple TV handoff")
struct HandoffTests {
    private func makeMessage(
        sessionId: String = "session-123",
        title: String = "Café Éclair 🎮"
    ) -> HandoffMessage {
        HandoffMessage(
            game: TestGameFactory.make(id: "game-1", title: title),
            sessionId: sessionId,
            appId: "app-42",
            senderKind: .iPad
        )
    }

    private func listed(_ sessionId: String, serverIp: String?) -> ActiveSessionInfo {
        ActiveSessionInfo(
            sessionId: sessionId,
            status: 2,
            appId: "app-42",
            serverIp: serverIp,
            signalingUrl: nil,
            controlServerIp: nil
        )
    }

    @Test("F01-H1 A message survives encode and decode intact")
    func roundTrip() throws {
        let message = makeMessage()
        let decoded = try #require(HandoffMessage.decode(message.encoded()))

        #expect(decoded.version == HandoffMessage.currentVersion)
        #expect(decoded.senderKind == .iPad)
        #expect(decoded.game == message.game)
        #expect(decoded.game.title == "Café Éclair 🎮")
        #expect(decoded.sessionId == "session-123")
        #expect(decoded.appId == "app-42")
    }

    @Test("F01-H2 The receiver resumes only the session NVIDIA lists, with NVIDIA's address")
    func resolvesAgainstServerList() throws {
        let message = makeMessage()
        let sessions = [
            listed("other-session", serverIp: "203.0.113.9"),
            listed("session-123", serverIp: "198.51.100.4"),
        ]

        let match = try #require(message.matchingSession(in: sessions))
        #expect(match.sessionId == "session-123")
        #expect(match.serverIp == "198.51.100.4")
    }

    @Test("F01-N4 An unlisted or address-less session is never resumed")
    func refusesUnlistedSessions() {
        let message = makeMessage()

        #expect(message.matchingSession(in: []) == nil)
        #expect(message.matchingSession(in: [listed("other-session", serverIp: "203.0.113.9")]) == nil)
        #expect(message.matchingSession(in: [listed("session-123", serverIp: nil)]) == nil)
        #expect(message.matchingSession(in: [listed("session-123", serverIp: "")]) == nil)
    }

    @Test("F01-N5 The wire format carries no server address")
    func noServerAddressOnTheWire() throws {
        let json = try #require(
            JSONSerialization.jsonObject(with: makeMessage().encoded()) as? [String: Any]
        )
        #expect(json["serverIp"] == nil)
        #expect(json["signalingUrl"] == nil)
    }

    @Test("F01-N1 Garbage, empty and truncated payloads are rejected")
    func rejectsMalformedPayloads() throws {
        #expect(HandoffMessage.decode(Data()) == nil)
        #expect(HandoffMessage.decode(Data("not json".utf8)) == nil)

        let full = try makeMessage().encoded()
        #expect(HandoffMessage.decode(full.prefix(full.count / 2)) == nil)
    }

    @Test("F01-N2 A message with an empty or absurd session identifier is rejected")
    func rejectsBadSessionIdentifiers() throws {
        #expect(try HandoffMessage.decode(makeMessage(sessionId: "").encoded()) == nil)
        let long = String(repeating: "a", count: HandoffMessage.maxSessionIdLength + 1)
        #expect(try HandoffMessage.decode(makeMessage(sessionId: long).encoded()) == nil)
    }

    @Test("F01-N3 A message from a different protocol version is rejected")
    func rejectsOtherVersions() throws {
        let encoded = try makeMessage().encoded()
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["version"] = HandoffMessage.currentVersion + 1
        let altered = try JSONSerialization.data(withJSONObject: json)

        #expect(HandoffMessage.decode(altered) == nil)
    }

    @Test("F01-E1 Oversized payloads are rejected before decoding")
    func rejectsOversizedPayloads() throws {
        let huge = String(repeating: "x", count: HandoffMessage.maxEncodedBytes)
        let encoded = try makeMessage(title: huge).encoded()

        #expect(encoded.count > HandoffMessage.maxEncodedBytes)
        #expect(HandoffMessage.decode(encoded) == nil)
    }

    @Test("F01-E2 Forgetting a handed-off lease never schedules a server End")
    @MainActor
    func releasedLeaseIsForgottenNotParked() throws {
        let coordinator = CloudSessionCoordinator()
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "session-123"
        )

        coordinator.endServerSession(lease)

        #expect(coordinator.serverSession == nil)
        #expect(coordinator.sessionPendingEnd == nil)
        // The device that sent the session is free to start or receive another.
        let next = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "session-456"
        )
        #expect(next.serverSessionID == "session-456")
    }

    @Test("F01-H3 This build advertises the right device kind")
    func deviceKind() {
        #if os(tvOS)
            #expect(HandoffDeviceKind.current == .appleTV)
        #elseif targetEnvironment(macCatalyst)
            #expect(HandoffDeviceKind.current == .mac)
        #else
            #expect(HandoffDeviceKind.current == .iPad)
        #endif
    }

    @Test("F01-H4 Handoff labels name the target device")
    func labels() {
        #expect(!HandoffText.sendTo(.appleTV).isEmpty)
        #expect(!HandoffText.sendTo(.iPad).isEmpty)
        #expect(HandoffText.sendTo(.appleTV) != HandoffText.sendTo(.iPad))
        #expect(HandoffText.receiving("Halo").contains("Halo"))
        #expect(!HandoffText.notFound.isEmpty)
    }
}
