import Foundation
import Network
import os.log

private let relayLog = Logger(subsystem: "com.waessa.CloudTV", category: "GamepadRelay")

/// XInput-shaped state of a controller that is physically paired to another
/// Cloud TV device and relayed over the local network.
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

/// Fixed-size datagram: magic, token, sequence, state.
nonisolated enum RelayedGamepadPacket {
    static let magic: [UInt8] = [0x43, 0x54, 0x47, 0x31] // "CTG1"
    static let size = 4 + 8 + 4 + 2 + 1 + 1 + 2 * 4 + 1

    static func encode(_ state: RelayedGamepadState, token: UInt64, sequence: UInt32) -> Data {
        var data = Data(capacity: size)
        data.append(contentsOf: magic)
        append(&data, token)
        append(&data, sequence)
        append(&data, state.buttons)
        data.append(state.leftTrigger)
        data.append(state.rightTrigger)
        append(&data, UInt16(bitPattern: state.leftStickX))
        append(&data, UInt16(bitPattern: state.leftStickY))
        append(&data, UInt16(bitPattern: state.rightStickX))
        append(&data, UInt16(bitPattern: state.rightStickY))
        data.append(state.menuPresses)
        return data
    }

    static func decode(_ data: Data) -> (token: UInt64, sequence: UInt32, state: RelayedGamepadState)? {
        let bytes = [UInt8](data)
        guard bytes.count == size, Array(bytes[0 ..< 4]) == magic else { return nil }
        var offset = 4
        let token: UInt64 = read(bytes, &offset)
        let sequence: UInt32 = read(bytes, &offset)
        var state = RelayedGamepadState()
        state.buttons = read(bytes, &offset)
        state.leftTrigger = bytes[offset]
        state.rightTrigger = bytes[offset + 1]
        offset += 2
        state.leftStickX = Int16(bitPattern: read(bytes, &offset))
        state.leftStickY = Int16(bitPattern: read(bytes, &offset))
        state.rightStickX = Int16(bitPattern: read(bytes, &offset))
        state.rightStickY = Int16(bitPattern: read(bytes, &offset))
        state.menuPresses = bytes[offset]
        return (token, sequence, state)
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: inout Int) -> T {
        var value: T = 0
        for index in 0 ..< MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        offset += MemoryLayout<T>.size
        return value
    }
}

/// Receiving side (Apple TV): holds the latest relayed state for the running
/// InputSender to sample. Only packets carrying the token agreed in the
/// handoff are accepted, and a state older than `staleAfter` reads as absent so
/// a lost iPad never leaves a button stuck down.
final nonisolated class RemoteGamepadInbox: @unchecked Sendable {
    static let shared = RemoteGamepadInbox()

    static let staleAfterNanoseconds: UInt64 = 750_000_000

    private let lock = NSLock()
    private var token: UInt64?
    private var lastSequence: UInt32?
    private var state: RelayedGamepadState?
    private var receivedAt: UInt64 = 0
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    func beginSession(token: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
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

    /// Returns true when the packet was accepted.
    @discardableResult
    func accept(_ data: Data) -> Bool {
        guard let packet = RelayedGamepadPacket.decode(data) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let token, packet.token == token else { return false }
        // Drop reordered datagrams; allow wrap-around.
        if let lastSequence, packet.sequence &- lastSequence > UInt32.max / 2 || packet.sequence == lastSequence {
            return false
        }
        lastSequence = packet.sequence
        state = packet.state
        receivedAt = now()
        return true
    }

    /// The current relayed state, or nil when no fresh state is available.
    func current() -> RelayedGamepadState? {
        lock.lock()
        defer { lock.unlock() }
        guard token != nil, let state, now() &- receivedAt <= Self.staleAfterNanoseconds else {
            return nil
        }
        return state
    }
}

/// UDP endpoint on the Apple TV that feeds `RemoteGamepadInbox`.
@MainActor
final class RemoteGamepadReceiver {
    static let serviceType = "_cloudtvpad._udp"

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

    private nonisolated static func makeConnectionHandler(
        queue: DispatchQueue
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            connection.start(queue: queue)
            receive(on: connection)
        }
    }

    private nonisolated static func receive(on connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            if let data {
                RemoteGamepadInbox.shared.accept(data)
            }
            if error == nil {
                receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }
}

/// Sending side (iPad): samples the locally paired controller and streams its
/// state to the Apple TV, at 120 Hz on change and every 50 ms otherwise.
final nonisolated class RemoteGamepadSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.waessa.CloudTV.relay.send", qos: .userInteractive)
    private let token: UInt64
    private let connection: NWConnection
    private let sample: @Sendable () -> RelayedGamepadState?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private var lastSent: RelayedGamepadState?
    private var lastSentAt: UInt64 = 0

    private static let sampleInterval = DispatchTimeInterval.nanoseconds(8_333_333)
    private static let keepAliveNanoseconds: UInt64 = 50_000_000

    init(
        toServiceNamed name: String,
        token: UInt64,
        sample: @escaping @Sendable () -> RelayedGamepadState?
    ) {
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        connection = NWConnection(
            to: .service(name: name, type: RemoteGamepadReceiver.serviceType, domain: "local.", interface: nil),
            using: parameters
        )
        self.token = token
        self.sample = sample
    }

    func start() {
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.sampleInterval, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        queue.async { self.timer = timer }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            // Leave the TV with a neutral pad rather than a held button.
            send(.neutral)
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [connection] in connection.cancel() }
    }

    private func tick() {
        let state = sample() ?? .neutral
        let now = DispatchTime.now().uptimeNanoseconds
        guard state != lastSent || now &- lastSentAt >= Self.keepAliveNanoseconds else { return }
        send(state)
        lastSent = state
        lastSentAt = now
    }

    private func send(_ state: RelayedGamepadState) {
        sequence &+= 1
        let data = RelayedGamepadPacket.encode(state, token: token, sequence: sequence)
        connection.send(content: data, completion: .idempotent)
    }
}
