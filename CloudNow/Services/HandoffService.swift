import Foundation
import Network
import os.log

private let handoffLog = Logger(subsystem: "com.waessa.CloudTV", category: "Handoff")

/// The kind of device running Cloud TV, advertised to peers on the local network.
nonisolated enum HandoffDeviceKind: String, Codable, Sendable {
    case appleTV = "tv"
    case iPad = "ipad"

    static var current: HandoffDeviceKind {
        #if os(tvOS)
            .appleTV
        #else
            .iPad
        #endif
    }
}

/// A Cloud TV instance discovered on the local network.
nonisolated struct HandoffPeer: Identifiable, Hashable, Sendable {
    /// Bonjour service instance name; unique per running app.
    let id: String
    let kind: HandoffDeviceKind
    let endpoint: NWEndpoint
}

/// Everything the receiving device needs to resume a GeForce NOW session that
/// the sending device has just left. The server session itself never moves: it
/// keeps running at NVIDIA, and the receiver claims it like any session started
/// on another device.
nonisolated struct HandoffMessage: Codable {
    static let currentVersion = 1

    let version: Int
    let senderKind: HandoffDeviceKind
    let game: GameInfo
    let sessionId: String
    let appId: String?
    let serverIp: String
    let signalingUrl: String?

    init(
        game: GameInfo,
        sessionId: String,
        appId: String?,
        serverIp: String,
        signalingUrl: String?,
        senderKind: HandoffDeviceKind = .current
    ) {
        version = Self.currentVersion
        self.senderKind = senderKind
        self.game = game
        self.sessionId = sessionId
        self.appId = appId
        self.serverIp = serverIp
        self.signalingUrl = signalingUrl
    }

    /// The server-list shape StreamView already knows how to resume.
    var activeSessionInfo: ActiveSessionInfo {
        ActiveSessionInfo(
            sessionId: sessionId,
            status: 2,
            appId: appId,
            serverIp: serverIp,
            signalingUrl: signalingUrl,
            controlServerIp: nil
        )
    }

    static let maxEncodedBytes = 256 * 1024

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> HandoffMessage? {
        guard data.count <= maxEncodedBytes,
              let message = try? JSONDecoder().decode(HandoffMessage.self, from: data),
              message.version == currentVersion,
              !message.sessionId.isEmpty,
              !message.serverIp.isEmpty
        else {
            return nil
        }
        return message
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
