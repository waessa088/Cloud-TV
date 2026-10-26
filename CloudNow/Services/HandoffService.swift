import Foundation
import GameController
import Network
#if canImport(UIKit)
    import UIKit
#endif
import os.log

private let handoffLog = Logger(subsystem: "com.waessa.CloudTV", category: "Handoff")

/// The kind of device running Cloud TV, advertised to peers on the local network.
nonisolated enum HandoffDeviceKind: String, Codable, Sendable {
    case appleTV = "tv"
    case iPad = "ipad"
    case mac

    static var current: HandoffDeviceKind {
        #if os(tvOS)
            .appleTV
        #elseif targetEnvironment(macCatalyst)
            .mac
        #else
            .iPad
        #endif
    }

    /// iPad and Mac keep the controller and relay it; only the TV receives.
    var canRelayController: Bool {
        self != .appleTV
    }

    var systemImage: String {
        switch self {
        case .appleTV: "appletv"
        case .iPad: "ipad.landscape"
        case .mac: "macbook"
        }
    }
}

/// A Cloud TV instance discovered on the local network.
nonisolated struct HandoffPeer: Identifiable, Hashable, Sendable {
    /// Bonjour service instance name; unique per running app.
    let id: String
    let kind: HandoffDeviceKind
    let endpoint: NWEndpoint
}

/// Identifies a GeForce NOW session that the sending device has just left.
/// The server session itself never moves: it keeps running at NVIDIA and the
/// receiver claims it like any session started on another device.
///
/// Security: the message carries no server address. A peer on the local
/// network is untrusted, and the resume request carries the NVIDIA token, so the
/// receiver only ever claims a session it finds in NVIDIA's own active-session
/// list, using the server address that list returns.
nonisolated struct HandoffMessage: Codable {
    static let currentVersion = 1
    static let maxEncodedBytes = 256 * 1024
    static let maxSessionIdLength = 256

    let version: Int
    let senderKind: HandoffDeviceKind
    let game: GameInfo
    let sessionId: String
    let appId: String?
    /// Present when the sender keeps the controller and relays it (hex UInt64).
    let relayToken: String?
    /// When true the sender takes the session back: the receiver should let go
    /// of it (without ending it) instead of resuming it.
    let release: Bool?
    /// The sender's controller mode, so the receiver applies the same routing.
    let controllerMode: String?

    init(
        game: GameInfo,
        sessionId: String,
        appId: String?,
        relayToken: UInt64? = nil,
        release: Bool = false,
        controllerMode: ControllerMode? = nil,
        senderKind: HandoffDeviceKind = .current
    ) {
        version = Self.currentVersion
        self.senderKind = senderKind
        self.game = game
        self.sessionId = sessionId
        self.appId = appId
        self.relayToken = relayToken.map { String($0, radix: 16) }
        self.release = release ? true : nil
        self.controllerMode = controllerMode?.rawValue
    }

    var controllerModeValue: ControllerMode {
        controllerMode.flatMap(ControllerMode.init(rawValue:)) ?? .automatic
    }

    var isRelease: Bool {
        release == true
    }

    /// The relay token, when the sender relays its controller.
    var relayTokenValue: UInt64? {
        relayToken.flatMap { UInt64($0, radix: 16) }
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> HandoffMessage? {
        guard data.count <= maxEncodedBytes,
              let message = try? JSONDecoder().decode(HandoffMessage.self, from: data),
              message.version == currentVersion,
              !message.sessionId.isEmpty,
              message.sessionId.count <= maxSessionIdLength
        else {
            return nil
        }
        return message
    }

    /// The session NVIDIA lists under this message's identifier, if any. Only
    /// a listed session with a server address can be resumed.
    func matchingSession(in sessions: [ActiveSessionInfo]) -> ActiveSessionInfo? {
        sessions.first { $0.sessionId == sessionId && $0.serverIp?.isEmpty == false }
    }
}

/// Discovers other Cloud TV devices on the local network (Bonjour) and moves a
/// running GeForce NOW session between them with a single message.
@Observable
@MainActor
final class HandoffService {
    static let shared = HandoffService()

    static let serviceType = "_cloudtv._tcp"

    /// Other Cloud TV devices currently visible on the network.
    private(set) var peers: [HandoffPeer] = []
    /// A session another device asked this one to resume. Consumers clear it.
    var incoming: HandoffMessage?
    /// Set on the iPad while its controller drives a game on the Apple TV.
    private(set) var relay: RelayState?
    /// A session another device is taking back; the player streaming it lets go.
    var releaseRequestedSessionId: String?
    /// Set after a handoff in direct-Bluetooth mode: the player has to move the
    /// controller pairing by hand, so the home screen explains how.
    var showsPairingHint = false

    struct RelayState {
        let peer: HandoffPeer
        let game: GameInfo
        let sessionId: String
        let appId: String?
        let controllerName: String
        let mode: ControllerMode
    }

    /// Live state of the relay link, refreshed a few times per second.
    private(set) var relayStatus = RelayLinkStatus()

    @ObservationIgnored private var relaySender: RemoteGamepadSender?
    @ObservationIgnored private var relayReceiver: RemoteGamepadReceiver?

    @ObservationIgnored private let instanceName = "CloudTV-\(UUID().uuidString.prefix(8))"
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.waessa.CloudTV.handoff")
    @ObservationIgnored private var restartAttempts = 0

    private init() {}

    /// Peers of the other device kind (iPad ↔ Apple TV), the useful handoff targets.
    var targets: [HandoffPeer] {
        peers.filter { $0.kind != HandoffDeviceKind.current }
    }

    var isRunning: Bool {
        listener != nil
    }

    func start() {
        guard listener == nil else { return }
        startListener()
        startBrowser()
        #if os(tvOS)
            if relayReceiver == nil {
                let receiver = RemoteGamepadReceiver()
                receiver.start(instanceName: instanceName)
                relayReceiver = receiver
            }
        #endif
    }

    // MARK: - Controller relay

    /// The controller to relay, when one is connected to this device.
    var relayableController: GCController? {
        LocalGamepadSampler.preferredController()
    }

    /// iPad: keeps the local controller and streams it to `peer` after a handoff.
    func startRelay(
        token: UInt64,
        to peer: HandoffPeer,
        game: GameInfo,
        sessionId: String,
        appId: String?,
        mode: ControllerMode,
        deadzone: Float
    ) {
        stopRelay()
        relayStatus = RelayLinkStatus()
        let sender = RemoteGamepadSender(toServiceNamed: peer.id, token: token, deadzone: deadzone) { status in
            Task { @MainActor in
                HandoffService.shared.relayStatus = status
            }
        }
        sender.start()
        relaySender = sender
        relay = RelayState(
            peer: peer,
            game: game,
            sessionId: sessionId,
            appId: appId,
            controllerName: relayableController?.vendorName ?? "Manette",
            mode: mode
        )
        setIdleTimerDisabled(true)
        handoffLog.info("Relaying the controller to \(peer.kind.rawValue, privacy: .public)")
    }

    /// iPad: takes the relayed game back. Asks the TV to let go first so it
    /// does not sit on a disconnect screen; resumes here either way.
    func takeBackRelayedGame() async -> HandoffMessage? {
        guard let relay else { return nil }
        stopRelay()
        let release = HandoffMessage(
            game: relay.game,
            sessionId: relay.sessionId,
            appId: relay.appId,
            release: true
        )
        _ = await send(release, to: relay.peer)
        return HandoffMessage(game: relay.game, sessionId: relay.sessionId, appId: relay.appId)
    }

    func stopRelay() {
        relaySender?.stop()
        relaySender = nil
        if relay != nil {
            relay = nil
            setIdleTimerDisabled(false)
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        peers = []
    }

    /// Sends the session to `peer`. Returns true once the message is delivered
    /// to the peer's TCP stack; the caller only leaves its stream after that.
    func send(_ message: HandoffMessage, to peer: HandoffPeer) async -> Bool {
        let data: Data
        do {
            data = try message.encoded()
        } catch {
            handoffLog.error("Encoding failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        let delivered = await Self.deliver(data, over: connection, queue: queue)
        handoffLog.info("Handoff to \(peer.kind.rawValue, privacy: .public): \(delivered ? "delivered" : "failed", privacy: .public)")
        return delivered
    }

    // MARK: - Listener

    private func startListener() {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            handoffLog.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var txt = NWTXTRecord()
        txt["kind"] = HandoffDeviceKind.current.rawValue
        listener.service = NWListener.Service(
            name: instanceName,
            type: Self.serviceType,
            domain: nil,
            txtRecord: txt
        )
        listener.newConnectionHandler = Self.makeConnectionHandler(queue: queue) { @Sendable [weak self] data in
            Task { @MainActor in
                self?.handleIncoming(data)
            }
        }
        listener.stateUpdateHandler = Self.makeListenerStateHandler { @Sendable [weak self] in
            Task { @MainActor in
                self?.restartAfterFailure()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func handleIncoming(_ data: Data) {
        guard let message = HandoffMessage.decode(data) else {
            handoffLog.warning("Ignored an invalid handoff message (\(data.count, privacy: .public) bytes)")
            return
        }
        handoffLog.info("Received a handoff from \(message.senderKind.rawValue, privacy: .public)")
        if message.isRelease {
            RemoteGamepadInbox.shared.endSession()
            releaseRequestedSessionId = message.sessionId
            return
        }
        if let token = message.relayTokenValue {
            RemoteGamepadInbox.shared.beginSession(
                token: token,
                mode: message.controllerModeValue,
                directControllerActive: LocalGamepadSampler.preferredController() != nil
            )
        } else {
            RemoteGamepadInbox.shared.endSession()
        }
        incoming = message
    }

    /// Retries a failed listener a few times with a delay instead of spinning.
    private func restartAfterFailure() {
        guard restartAttempts < 3 else { return }
        restartAttempts += 1
        stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.start()
        }
    }

    // MARK: - Browser

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = Self.makeBrowseHandler(excluding: instanceName) { @Sendable [weak self] peers in
            Task { @MainActor in
                self?.peers = peers
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: - Network callbacks

    // Network.framework calls these on `queue`. They are built in nonisolated
    // context so they never inherit main-actor isolation; main-actor work hops
    // explicitly through Task { @MainActor in }.

    private nonisolated static func makeConnectionHandler(
        queue: DispatchQueue,
        onMessage: @escaping @Sendable (Data) -> Void
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            connection.start(queue: queue)
            receiveAll(on: connection, buffer: Data()) { data in
                connection.cancel()
                if let data {
                    onMessage(data)
                }
            }
        }
    }

    private nonisolated static func makeListenerStateHandler(
        onFailure: @escaping @Sendable () -> Void
    ) -> @Sendable (NWListener.State) -> Void {
        { state in
            if case let .failed(error) = state {
                handoffLog.error("Listener state failed: \(error.localizedDescription, privacy: .public)")
                onFailure()
            }
        }
    }

    private nonisolated static func makeBrowseHandler(
        excluding ownName: String,
        onPeers: @escaping @Sendable ([HandoffPeer]) -> Void
    ) -> @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void {
        { results, _ in
            let peers = results.compactMap { peer(from: $0, excluding: ownName) }
                .sorted { $0.id < $1.id }
            onPeers(peers)
        }
    }

    private nonisolated static func peer(
        from result: NWBrowser.Result,
        excluding ownName: String
    ) -> HandoffPeer? {
        guard case let .service(name, _, _, _) = result.endpoint, name != ownName else {
            return nil
        }
        var kind: HandoffDeviceKind?
        if case let .bonjour(txt) = result.metadata, let raw = txt["kind"] {
            kind = HandoffDeviceKind(rawValue: raw)
        }
        guard let kind else { return nil }
        return HandoffPeer(id: name, kind: kind, endpoint: result.endpoint)
    }

    // MARK: - Transport

    /// Reads until the sender closes its side, bounded by `maxEncodedBytes`.
    private nonisolated static func receiveAll(
        on connection: NWConnection,
        buffer: Data,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if buffer.count > HandoffMessage.maxEncodedBytes {
                completion(nil)
            } else if isComplete {
                completion(buffer.isEmpty ? nil : buffer)
            } else if error != nil {
                completion(nil)
            } else {
                receiveAll(on: connection, buffer: buffer, completion: completion)
            }
        }
    }

    private nonisolated static func deliver(
        _ data: Data,
        over connection: NWConnection,
        queue: DispatchQueue,
        timeout: TimeInterval = 5
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: data,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { error in
                            once.resume(error == nil)
                            // Let the final bytes drain before tearing down.
                            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
                        }
                    )
                case .failed, .cancelled:
                    once.resume(false)
                case let .waiting(error):
                    handoffLog.warning("Handoff connection waiting: \(error.localizedDescription, privacy: .public)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.resume(false) {
                    connection.cancel()
                }
            }
        }
    }
}

/// Resumes a checked continuation exactly once across racing callbacks.
private final nonisolated class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// Returns true when this call performed the resume.
    @discardableResult
    func resume(_ value: Bool) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }
}
