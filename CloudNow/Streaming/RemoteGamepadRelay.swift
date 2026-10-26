import Foundation
import GameController
import Network
import os.log

private let relayLog = Logger(subsystem: "com.waessa.CloudTV", category: "GamepadRelay")

/// XInput-shaped state of a controller that is physically paired to another
/// Nimbus device and relayed over the local network.
nonisolated struct RelayedGamepadState: Equatable, Sendable {
    var buttons: UInt16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var leftStickX: Int16 = 0
    var leftStickY: Int16 = 0
    var rightStickX: Int16 = 0
    var rightStickY: Int16 = 0
    /// Increments each time the sender asks to toggle the pause menu.
    var menuPresses: UInt8 = 0

    static let neutral = RelayedGamepadState()
}

/// iPad → Apple TV datagram: magic, token, sequence, sender clock, state.
/// Sticks and triggers travel at full resolution (16-bit sticks, 8-bit
/// triggers, exactly what the stream input encoder takes), with no smoothing.
nonisolated enum RelayedGamepadPacket {
    static let magic: [UInt8] = [0x43, 0x54, 0x47, 0x32] // "CTG2"
    static let size = 4 + 8 + 4 + 8 + 2 + 1 + 1 + 2 * 4 + 1

    struct Decoded: Equatable {
        let token: UInt64
        let sequence: UInt32
        /// Sender's monotonic clock when the state was read, echoed back in acks.
        let sentAt: UInt64
        let state: RelayedGamepadState
    }

    static func encode(
        _ state: RelayedGamepadState,
        token: UInt64,
        sequence: UInt32,
        sentAt: UInt64 = 0
    ) -> Data {
        var data = Data(capacity: size)
        data.append(contentsOf: magic)
        RelayWire.append(&data, token)
        RelayWire.append(&data, sequence)
        RelayWire.append(&data, sentAt)
        RelayWire.append(&data, state.buttons)
        data.append(state.leftTrigger)
        data.append(state.rightTrigger)
        RelayWire.append(&data, UInt16(bitPattern: state.leftStickX))
        RelayWire.append(&data, UInt16(bitPattern: state.leftStickY))
        RelayWire.append(&data, UInt16(bitPattern: state.rightStickX))
        RelayWire.append(&data, UInt16(bitPattern: state.rightStickY))
        data.append(state.menuPresses)
        return data
    }

    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data)
        guard bytes.count == size, Array(bytes[0 ..< 4]) == magic else { return nil }
        var offset = 4
        let token: UInt64 = RelayWire.read(bytes, &offset)
        let sequence: UInt32 = RelayWire.read(bytes, &offset)
        let sentAt: UInt64 = RelayWire.read(bytes, &offset)
        var state = RelayedGamepadState()
        state.buttons = RelayWire.read(bytes, &offset)
        state.leftTrigger = bytes[offset]
        state.rightTrigger = bytes[offset + 1]
        offset += 2
        state.leftStickX = Int16(bitPattern: RelayWire.read(bytes, &offset))
        state.leftStickY = Int16(bitPattern: RelayWire.read(bytes, &offset))
        state.rightStickX = Int16(bitPattern: RelayWire.read(bytes, &offset))
        state.rightStickY = Int16(bitPattern: RelayWire.read(bytes, &offset))
        state.menuPresses = bytes[offset]
        return Decoded(token: token, sequence: sequence, sentAt: sentAt, state: state)
    }
}

/// Apple TV → iPad datagram, sent once the TV has handed a state to the
/// stream input path. Echoes the sender clock so the iPad measures the round
/// trip on its own clock; no clock synchronisation is needed.
nonisolated enum RelayAckPacket {
    static let magic: [UInt8] = [0x43, 0x54, 0x41, 0x32] // "CTA2"
    static let size = 4 + 8 + 4 + 8 + 1

    static let flagRelayInUse: UInt8 = 0x01
    static let flagDirectController: UInt8 = 0x02

    struct Decoded: Equatable {
        let token: UInt64
        let sequence: UInt32
        let echoedSentAt: UInt64
        let flags: UInt8

        var relayInUse: Bool {
            flags & RelayAckPacket.flagRelayInUse != 0
        }

        var tvHasDirectController: Bool {
            flags & RelayAckPacket.flagDirectController != 0
        }
    }

    static func encode(token: UInt64, sequence: UInt32, echoedSentAt: UInt64, flags: UInt8) -> Data {
        var data = Data(capacity: size)
        data.append(contentsOf: magic)
        RelayWire.append(&data, token)
        RelayWire.append(&data, sequence)
        RelayWire.append(&data, echoedSentAt)
        data.append(flags)
        return data
    }

    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data)
        guard bytes.count == size, Array(bytes[0 ..< 4]) == magic else { return nil }
        var offset = 4
        let token: UInt64 = RelayWire.read(bytes, &offset)
        let sequence: UInt32 = RelayWire.read(bytes, &offset)
        let echoed: UInt64 = RelayWire.read(bytes, &offset)
        return Decoded(token: token, sequence: sequence, echoedSentAt: echoed, flags: bytes[offset])
    }
}

/// Little-endian helpers shared by both packets.
nonisolated enum RelayWire {
    static func append(_ data: inout Data, _ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func read<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: inout Int) -> T {
        var value: T = 0
        for index in 0 ..< MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        offset += MemoryLayout<T>.size
        return value
    }
}

/// Receiving side (Apple TV): holds the latest relayed state for the running
/// InputSender. Only packets carrying the token agreed in the handoff are
/// accepted, and a state older than `staleAfter` reads as absent so a lost
/// iPad never leaves a button stuck down.
final nonisolated class RemoteGamepadInbox: @unchecked Sendable {
    static let shared = RemoteGamepadInbox()

    static let staleAfterNanoseconds: UInt64 = 750_000_000

    /// What `accept` tells the network layer, to build the acknowledgement.
    struct Accepted: Equatable {
        let sequence: UInt32
        let sentAt: UInt64
        let flags: UInt8
    }

    private let lock = NSLock()
    private var token: UInt64?
    private var mode: ControllerMode = .automatic
    private var directControllerActive = false
    private var lastSequence: UInt32?
    private var state: RelayedGamepadState?
    private var receivedAt: UInt64 = 0
    private var update: (@Sendable () -> Void)?
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    func beginSession(token: UInt64, mode: ControllerMode = .automatic, directControllerActive: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
        self.mode = mode
        self.directControllerActive = directControllerActive
        lastSequence = nil
        state = nil
        receivedAt = 0
    }

    func endSession() {
        lock.lock()
        defer { lock.unlock() }
        token = nil
        lastSequence = nil
        state = nil
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    /// The TV's InputSender reports whether a controller is connected to the
    /// TV directly; in automatic mode that suspends the relay.
    func setDirectControllerActive(_ active: Bool) {
        lock.lock()
        directControllerActive = active
        lock.unlock()
    }

    /// Called on the network queue after each accepted state, so the stream
    /// input path can forward it at once instead of waiting for its next tick.
    func setUpdateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        update = handler
        lock.unlock()
    }

    var relayInUse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return relayInUseLocked
    }

    private var relayInUseLocked: Bool {
        token != nil && ControllerRoutingPolicy.receiverUsesRelay(
            mode: mode,
            tvHasDirectController: directControllerActive
        )
    }

    private var flagsLocked: UInt8 {
        (relayInUseLocked ? RelayAckPacket.flagRelayInUse : 0)
            | (directControllerActive ? RelayAckPacket.flagDirectController : 0)
    }

    /// Returns what to acknowledge, or nil when the packet was rejected.
    @discardableResult
    func accept(_ data: Data) -> Accepted? {
        guard let packet = RelayedGamepadPacket.decode(data) else { return nil }
        lock.lock()
        guard let token, packet.token == token else {
            lock.unlock()
            return nil
        }
        // Drop reordered and duplicated datagrams; allow wrap-around.
        if let lastSequence, packet.sequence &- lastSequence > UInt32.max / 2 || packet.sequence == lastSequence {
            lock.unlock()
            return nil
        }
        lastSequence = packet.sequence
        state = packet.state
        receivedAt = now()
        let accepted = Accepted(sequence: packet.sequence, sentAt: packet.sentAt, flags: flagsLocked)
        let handler = update
        lock.unlock()
        handler?()
        return accepted
    }

    /// The current relayed state, or nil when it must not drive the game:
    /// no session, stale, or the relay is suspended by the routing policy.
    func current() -> RelayedGamepadState? {
        lock.lock()
        defer { lock.unlock() }
        guard relayInUseLocked, let state, now() &- receivedAt <= Self.staleAfterNanoseconds else {
            return nil
        }
        return state
    }
}

/// UDP endpoint on the Apple TV that feeds `RemoteGamepadInbox` and
/// acknowledges what it accepted.
@MainActor
final class RemoteGamepadReceiver {
    static let serviceType = "_cloudtvpad._udp"
    /// Acknowledge one state in this many; flag changes are always acknowledged.
    nonisolated static let ackEvery: UInt32 = 4

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.waessa.CloudTV.relay.receive", qos: .userInteractive)

    func start(instanceName: String) {
        guard listener == nil else { return }
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        guard let listener = try? NWListener(using: parameters) else {
            relayLog.error("Relay listener could not be created")
            return
        }
        listener.service = NWListener.Service(name: instanceName, type: Self.serviceType)
        listener.newConnectionHandler = Self.makeConnectionHandler(queue: queue)
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The UDP port once listening (used by the loopback latency benchmark).
    var port: UInt16? {
        listener?.port?.rawValue
    }

    private nonisolated static func makeConnectionHandler(
        queue: DispatchQueue
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            connection.start(queue: queue)
            receive(on: connection, lastFlags: nil)
        }
    }

    private nonisolated static func receive(on connection: NWConnection, lastFlags: UInt8?) {
        connection.receiveMessage { data, _, _, error in
            var flags = lastFlags
            if let data, let accepted = RemoteGamepadInbox.shared.accept(data),
               let token = RelayedGamepadPacket.decode(data)?.token
            {
                if accepted.sequence % ackEvery == 0 || accepted.flags != lastFlags {
                    let ack = RelayAckPacket.encode(
                        token: token,
                        sequence: accepted.sequence,
                        echoedSentAt: accepted.sentAt,
                        flags: accepted.flags
                    )
                    connection.send(content: ack, completion: .idempotent)
                }
                flags = accepted.flags
            }
            if error == nil {
                receive(on: connection, lastFlags: flags)
            } else {
                connection.cancel()
            }
        }
    }
}

/// What the iPad shows about a running relay.
nonisolated struct RelayLinkStatus: Equatable, Sendable {
    /// False when the TV says it is driven by its own Bluetooth controller.
    var relayInUse = true
    var tvHasDirectController = false
    var acknowledged = false
    var latency = LatencyStats()
}

/// Sending side (iPad): forwards the locally connected controller to the Apple
/// TV the moment its values change (GameController's change handler, no
/// polling loop), plus a keep-alive so the TV can tell the relay is alive.
final nonisolated class RemoteGamepadSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.waessa.CloudTV.relay.send", qos: .userInteractive)
    private let token: UInt64
    private let connection: NWConnection
    private let sampler: LocalGamepadSampler
    private let onStatus: @Sendable (RelayLinkStatus) -> Void
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var attached: GCController?
    private var sequence: UInt32 = 0
    private var lastSent: RelayedGamepadState?
    private var lastSentAt: UInt64 = 0
    private var status = RelayLinkStatus()
    private var lastStatusPublish: UInt64 = 0
    private var running = false

    init(
        toServiceNamed name: String,
        token: UInt64,
        deadzone: Float,
        onStatus: @escaping @Sendable (RelayLinkStatus) -> Void
    ) {
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        connection = NWConnection(
            to: .service(name: name, type: RemoteGamepadReceiver.serviceType, domain: "local.", interface: nil),
            using: parameters
        )
        self.token = token
        sampler = LocalGamepadSampler(deadzone: deadzone)
        self.onStatus = onStatus
    }

    func start() {
        queue.async { [self] in
            running = true
            connection.start(queue: queue)
            receiveAcks()
            attachCurrentController()
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: nil) { [weak self] _ in
                    self?.queue.async { self?.attachCurrentController() }
                },
                center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] _ in
                    self?.queue.async { self?.attachCurrentController() }
                },
            ]
            scheduleTimer()
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            detach()
            // Leave the TV with a neutral pad rather than a held button.
            send(.neutral, now: DispatchTime.now().uptimeNanoseconds)
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [connection] in connection.cancel() }
    }

    // MARK: Controller

    private func attachCurrentController() {
        guard running else { return }
        let controller = LocalGamepadSampler.preferredController()
        guard controller !== attached else { return }
        detach()
        attached = controller
        if let controller, let pad = controller.extendedGamepad {
            controller.handlerQueue = queue
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.valueChangedHandler = { [weak self] _, _ in
                self?.forwardNow()
            }
        }
        // A disconnect mid-game releases everything on the TV at once.
        forwardNow()
    }

    private func detach() {
        if let attached {
            attached.extendedGamepad?.valueChangedHandler = nil
            attached.handlerQueue = .main
        }
        attached = nil
    }

    /// Runs on `queue`: GameController delivers change events there.
    private func forwardNow() {
        guard running else { return }
        let state = sampler.sample(attached) ?? .neutral
        guard status.relayInUse || state.menuPresses != lastSent?.menuPresses else { return }
        guard state != lastSent else { return }
        send(state, now: DispatchTime.now().uptimeNanoseconds)
    }

    // MARK: Timer and acks

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.keepAlive() }
        timer.resume()
        self.timer = timer
    }

    private func keepAlive() {
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = ControllerRoutingPolicy.keepAliveInterval(relayInUse: status.relayInUse)
        guard now &- lastSentAt >= interval else { return }
        let state = status.relayInUse ? (sampler.sample(attached) ?? .neutral) : .neutral
        send(state, now: now)
    }

    private func send(_ state: RelayedGamepadState, now: UInt64) {
        sequence &+= 1
        let data = RelayedGamepadPacket.encode(state, token: token, sequence: sequence, sentAt: now)
        connection.send(content: data, completion: .idempotent)
        lastSent = state
        lastSentAt = now
    }

    private func receiveAcks() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let ack = RelayAckPacket.decode(data), ack.token == token {
                handle(ack)
            }
            if error == nil, running {
                receiveAcks()
            }
        }
    }

    private func handle(_ ack: RelayAckPacket.Decoded) {
        let now = DispatchTime.now().uptimeNanoseconds
        if ack.echoedSentAt > 0, now > ack.echoedSentAt {
            // One-way estimate: half the round trip, on this device's clock.
            status.latency.add((now - ack.echoedSentAt) / 2)
        }
        let wasInUse = status.relayInUse
        status.relayInUse = ack.relayInUse
        status.tvHasDirectController = ack.tvHasDirectController
        status.acknowledged = true
        if wasInUse != status.relayInUse || now &- lastStatusPublish >= 250_000_000 {
            lastStatusPublish = now
            onStatus(status)
        }
    }
}

/// Reads the locally connected controller for the relay, with the same
/// mapping and deadzone as local play. Only touched from the relay sender's
/// queue. The controller's Home (PS) button opens the pause menu on the TV
/// instead of reaching the game.
final nonisolated class LocalGamepadSampler: @unchecked Sendable {
    /// XInput Guide bit (GFNInput.guide); Home is used for the pause menu instead.
    private static let guideButtonMask: UInt16 = 0x0400
    private let deadzone: Float
    private var homeWasPressed = false
    private var menuPresses: UInt8 = 0

    init(deadzone: Float = 0.15) {
        self.deadzone = deadzone
    }

    static func preferredController() -> GCController? {
        if let current = GCController.current, current.extendedGamepad != nil {
            return current
        }
        return GCController.controllers().first { $0.extendedGamepad != nil }
    }

    func sample(_ controller: GCController?) -> RelayedGamepadState? {
        guard let controller, let pad = controller.extendedGamepad else { return nil }
        let homePressed = pad.buttonHome?.isPressed ?? false
        if homePressed, !homeWasPressed {
            menuPresses &+= 1
        }
        homeWasPressed = homePressed

        let mapped = mapGCControllerToXInput(controller, deadzone: deadzone)
        return RelayedGamepadState(
            buttons: mapped.buttons & ~Self.guideButtonMask,
            leftTrigger: mapped.leftTrigger,
            rightTrigger: mapped.rightTrigger,
            leftStickX: mapped.lx,
            leftStickY: mapped.ly,
            rightStickX: mapped.rx,
            rightStickY: mapped.ry,
            menuPresses: menuPresses
        )
    }
}
