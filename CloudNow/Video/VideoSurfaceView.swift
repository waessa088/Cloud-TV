// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
@preconcurrency import LiveKitWebRTC
import os
import UIKit

private nonisolated let videoLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Video")

nonisolated struct LatestFrameMailbox<Element> {
    enum StoreResult {
        case stored(replacing: Element?)
        case rejected(Element)
    }

    private var pending: Element?
    private(set) var isTerminated = false

    var hasPending: Bool {
        pending != nil
    }

    mutating func store(_ element: Element) -> StoreResult {
        guard !isTerminated else { return .rejected(element) }
        let replaced = pending
        pending = element
        return .stored(replacing: replaced)
    }

    mutating func storeIfEmpty(_ element: Element) -> Bool {
        guard !isTerminated, pending == nil else { return false }
        pending = element
        return true
    }

    mutating func take() -> Element? {
        defer { pending = nil }
        return pending
    }

    mutating func flush() -> Element? {
        take()
    }

    mutating func teardown() -> Element? {
        isTerminated = true
        return take()
    }
}

nonisolated struct VideoRendererDrainSchedule: Sendable {
    private(set) var isScheduled = false
    private(set) var identifier: UInt64 = 0

    mutating func beginIfNeeded() -> Bool {
        guard !isScheduled else { return false }
        identifier &+= 1
        isScheduled = true
        return true
    }

    mutating func finish() {
        isScheduled = false
    }

    func isCurrent(_ identifier: UInt64) -> Bool {
        isScheduled && self.identifier == identifier
    }
}

nonisolated struct VideoRendererFlushRequest: Equatable, Sendable {
    let generation: UInt64
    let removeDisplayedImage: Bool
}

nonisolated struct VideoRendererFlushPlan: Sendable {
    enum Completion: Equatable {
        case ignored
        case finished
        case followUp(VideoRendererFlushRequest)
    }

    private(set) var activeRequest: VideoRendererFlushRequest?
    private(set) var pendingRequest: VideoRendererFlushRequest?
    private var terminalFollowUp: VideoRendererFlushRequest?

    var hasScheduledWork: Bool {
        activeRequest != nil || pendingRequest != nil || terminalFollowUp != nil
    }

    mutating func begin(
        _ request: VideoRendererFlushRequest,
        activeEnqueues: Int
    ) -> VideoRendererFlushRequest? {
        precondition(!hasScheduledWork)
        if activeEnqueues == 0 {
            activeRequest = request
            return request
        }
        pendingRequest = request
        return nil
    }

    mutating func upgradeToTerminal(
        _ request: VideoRendererFlushRequest,
        activeEnqueues: Int
    ) -> VideoRendererFlushRequest? {
        if pendingRequest != nil {
            pendingRequest = request
            return nil
        }
        if let activeRequest {
            if !activeRequest.removeDisplayedImage {
                terminalFollowUp = request
            }
            return nil
        }
        if activeEnqueues == 0 {
            activeRequest = request
            return request
        }
        pendingRequest = request
        return nil
    }

    mutating func activatePendingAfterEnqueuesDrain() -> VideoRendererFlushRequest? {
        guard activeRequest == nil, let pendingRequest else { return nil }
        activeRequest = pendingRequest
        self.pendingRequest = nil
        return pendingRequest
    }

    mutating func complete(_ request: VideoRendererFlushRequest) -> Completion {
        guard activeRequest == request else { return .ignored }
        activeRequest = nil
        if let terminalFollowUp {
            self.terminalFollowUp = nil
            activeRequest = terminalFollowUp
            return .followUp(terminalFollowUp)
        }
        return .finished
    }
}

// MARK: - VideoSurfaceView

/// Full-screen video renderer.
/// Uses AVSampleBufferDisplayLayer as the backing layer (reliable on tvOS).
/// LKRTCMTLVideoView (MTKView wrapper) does not render on tvOS — bypassed entirely.
///
/// Also acts as first responder for hardware keyboard input and pointer (mouse)
/// input, forwarding events to `inputHandler` as GFN protocol packets.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private let pipelineDiagnostics = VideoPipelineDiagnostics()
    private lazy var renderer = WebRTCFrameRenderer(diagnostics: pipelineDiagnostics)
    private var currentTrack: LKRTCVideoTrack?
    private var notificationTokens: [NSObjectProtocol] = []
    private var activeRemoteTouch: UITouch?
    private var lastRemoteTouchLocation: CGPoint?
    private var remoteSelectMouseDown = false

    private static let remoteTouchSensitivity: CGFloat = 1.0

    /// Set by GFNStreamController once the input data channel handshake completes.
    weak var inputHandler: InputEventHandler?

    /// Called when the user presses the Menu button on the Siri Remote.
    /// GFNStreamController sets this to toggle the overlay rather than letting
    /// the press bubble up to the system (which opens the Apple TV control center).
    var menuPressHandler: (() -> Void)?

    var onDecodedVideoFormatChanged: (@Sendable (DecodedVideoFormat) -> Void)? {
        didSet {
            let handler = onDecodedVideoFormatChanged
            renderer.onDecodedVideoFormatChanged = { format in
                handler?(format)
            }
        }
    }

    /// When true, an extended gamepad owns input. UIKit presses from the controller
    /// (e.g. Options mapping to .playPause) are suppressed to avoid double-firing the overlay.
    var gamepadModeActive = false {
        didSet {
            if gamepadModeActive {
                cancelRemoteMouseTracking()
            }
        }
    }

    /// Tracks whether the pause overlay is currently visible. Used to decide whether a
    /// .menu press should close the overlay or be silently consumed.
    var overlayVisible: Bool = false {
        didSet {
            if overlayVisible {
                cancelRemoteMouseTracking()
            }
        }
    }

    var videoTrack: LKRTCVideoTrack? {
        didSet {
            guard oldValue !== videoTrack else { return }
            let hadTrack = currentTrack != nil
            currentTrack?.remove(renderer)
            if hadTrack {
                renderer.reset(preservingDisplayedImage: videoTrack != nil)
            }
            currentTrack = videoTrack
            if let track = videoTrack {
                track.add(renderer)
                videoLog.info("[VideoSurfaceView] Track attached")
            }
        }
    }

    func captureDiagnostics(_ completion: @escaping @Sendable (VideoPipelineSnapshot) -> Void) {
        renderer.capturePerformanceMetrics { [pipelineDiagnostics] in
            completion(pipelineDiagnostics.snapshot())
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        pipelineDiagnostics.setEnabled(enabled)
    }

    func setAdaptiveFramePacing(_ enabled: Bool, frameRate: Int) {
        renderer.setAdaptiveFramePacing(enabled, frameRate: frameRate)
    }

    /// Clears renderer and input ownership when SwiftUI dismantles the representable. The stream
    /// controller may temporarily retain this view while reconnecting, so teardown must not rely
    /// solely on UIKit deallocation.
    func prepareForDismantle() {
        resignFirstResponder()
        cancelRemoteMouseTracking()
        videoTrack = nil
        renderer.teardown()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        inputHandler = nil
        menuPressHandler = nil
        onDecodedVideoFormatChanged = nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        #if os(tvOS)
            displayLayer.videoGravity = .resizeAspectFill
        #else
            installSystemPointerSupport()
            // iPad screens are not 16:9: fill would crop the sides of the game,
            // so show the whole frame and letterbox the remainder.
            displayLayer.videoGravity = .resizeAspect
        #endif
        displayLayer.controlTimebase = nil

        let sampleBufferRenderer = displayLayer.sampleBufferRenderer
        renderer.sampleBufferRenderer = sampleBufferRenderer
        notificationTokens = [
            NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
                object: sampleBufferRenderer,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.recoverAfterFailure()
            },
            NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: sampleBufferRenderer,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.recoverIfRequired()
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.recoverIfRequired()
            },
        ]
    }

    isolated deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Become first responder as soon as the view enters a window so hardware
    /// keyboard events are directed here rather than the focus engine.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    // MARK: - First Responder / Keyboard

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            #if os(iOS)
                // ⌘⇧M toggles the stream menu from a keyboard (Mac and iPad).
                if let key = press.key,
                   key.modifierFlags.contains([.command, .shift]),
                   key.charactersIgnoringModifiers.lowercased() == "m"
                {
                    menuPressHandler?()
                    handled = true
                    continue
                }
                // iPadOS reports a controller's B / Circle as a Menu press. The
                // game already receives that button through GameController, and the
                // menu opens from the PS / Home button, so swallow it here.
                if press.key == nil, press.type == .menu || press.type == .playPause {
                    handled = true
                    continue
                }
            #endif
            if press.type == .menu {
                // Always consume .menu — never let it bubble to the system as a back/dismiss
                // gesture. Use it as the universal overlay toggle so the user can both open
                // and close the diagnostics overlay from Siri Remote or a controller.
                menuPressHandler?()
                handled = true
            } else if press.type == .playPause {
                // Play/Pause also toggles the overlay so Siri Remote users always have a
                // direct way to open diagnostics, even when a controller is connected.
                menuPressHandler?()
                handled = true
            } else if press.type == .select, remoteMouseInputEnabled {
                inputHandler?.sendMouseButton(down: true, button: 1)
                remoteSelectMouseDown = true
                handled = true
            } else if let key = press.key {
                inputHandler?.sendKeyEvent(
                    down: true,
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags
                )
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            #if os(iOS)
                if press.key == nil, press.type == .menu || press.type == .playPause {
                    handled = true
                    continue
                }
            #endif
            if press.type == .select, remoteSelectMouseDown {
                inputHandler?.sendMouseButton(down: false, button: 1)
                remoteSelectMouseDown = false
                handled = true
            } else if let key = press.key {
                inputHandler?.sendKeyEvent(
                    down: false,
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags
                )
                handled = true
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    // MARK: - Siri Remote Touch Surface

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        #if os(iOS)
            if handlePointerTouches(touches, event: event, phase: .began) {
                return
            }
        #endif
        guard remoteMouseInputEnabled,
              activeRemoteTouch == nil,
              let touch = touches.first(where: isRemoteTouch)
        else {
            super.touchesBegan(touches, with: event)
            return
        }

        activeRemoteTouch = touch
        lastRemoteTouchLocation = touch.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        #if os(iOS)
            if handlePointerTouches(touches, event: event, phase: .moved) {
                return
            }
        #endif
        guard remoteMouseInputEnabled else {
            clearRemoteTouchTracking()
            super.touchesMoved(touches, with: event)
            return
        }
        guard let trackedTouch = activeRemoteTouch,
              touches.contains(where: { $0 === trackedTouch })
        else {
            super.touchesMoved(touches, with: event)
            return
        }

        let location = trackedTouch.location(in: self)
        let previous = lastRemoteTouchLocation ?? trackedTouch.previousLocation(in: self)
        lastRemoteTouchLocation = location
        forwardRemoteTouchDelta(from: previous, to: location)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        #if os(iOS)
            if handlePointerTouches(touches, event: event, phase: .ended) {
                return
            }
        #endif
        guard let trackedTouch = activeRemoteTouch,
              touches.contains(where: { $0 === trackedTouch })
        else {
            super.touchesEnded(touches, with: event)
            return
        }

        activeRemoteTouch = nil
        lastRemoteTouchLocation = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        #if os(iOS)
            if handlePointerTouches(touches, event: event, phase: .ended) {
                return
            }
        #endif
        guard let trackedTouch = activeRemoteTouch,
              touches.contains(where: { $0 === trackedTouch })
        else {
            super.touchesCancelled(touches, with: event)
            return
        }

        activeRemoteTouch = nil
        lastRemoteTouchLocation = nil
    }

    private func isRemoteTouch(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .indirect, .indirectPointer:
            true
        default:
            false
        }
    }

    private func forwardRemoteTouchDelta(from previous: CGPoint, to location: CGPoint) {
        let dx = (location.x - previous.x) * Self.remoteTouchSensitivity
        let dy = (location.y - previous.y) * Self.remoteTouchSensitivity
        let packetDX = Int16(clamping: Int(dx.rounded()))
        let packetDY = Int16(clamping: Int(dy.rounded()))
        guard packetDX != 0 || packetDY != 0 else { return }
        inputHandler?.sendMouseMove(dx: packetDX, dy: packetDY)
    }

    // MARK: - iPadOS system pointer (Universal Control, trackpad)

    #if os(iOS)
        /// Pointer input that is not a GameController mouse: the Mac's keyboard and
        /// trackpad through Universal Control, or a trackpad. Converted to the same
        /// relative moves as GCMouse. Skipped while a GCMouse is connected, which
        /// already reports raw deltas and clicks.
        enum PointerPhase {
            case began
            case moved
            case ended
        }

        private static let pointerSensitivity: CGFloat = 1.6
        private var lastHoverLocation: CGPoint?
        private var pressedPointerButton: UInt8?
        private var lastScrollTranslation: CGFloat = 0

        private var systemPointerDrivesGame: Bool {
            !overlayVisible && GCMouse.mice().isEmpty
        }

        func installSystemPointerSupport() {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePointerHover(_:)))
            addGestureRecognizer(hover)
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(handlePointerScroll(_:)))
            scroll.allowedScrollTypesMask = .all
            scroll.allowedTouchTypes = []
            addGestureRecognizer(scroll)
        }

        @objc private func handlePointerHover(_ recognizer: UIHoverGestureRecognizer) {
            let location = recognizer.location(in: self)
            defer { lastHoverLocation = recognizer.state == .ended ? nil : location }
            guard systemPointerDrivesGame,
                  recognizer.state == .changed,
                  let previous = lastHoverLocation
            else { return }
            forwardPointerDelta(from: previous, to: location)
        }

        @objc private func handlePointerScroll(_ recognizer: UIPanGestureRecognizer) {
            guard systemPointerDrivesGame else { return }
            switch recognizer.state {
            case .began:
                lastScrollTranslation = 0
            case .changed:
                let translation = recognizer.translation(in: self).y
                let steps = Int(((translation - lastScrollTranslation) / 12).rounded(.towardZero))
                guard steps != 0 else { return }
                lastScrollTranslation += CGFloat(steps) * 12
                inputHandler?.sendMouseWheel(delta: Int16(clamping: steps * 3))
            default:
                lastScrollTranslation = 0
            }
        }

        /// Returns true when the touches were pointer clicks or drags it handled.
        func handlePointerTouches(_ touches: Set<UITouch>, event: UIEvent?, phase: PointerPhase) -> Bool {
            guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return false }
            guard systemPointerDrivesGame else { return !overlayVisible }
            switch phase {
            case .began:
                let button: UInt8 = event?.buttonMask.contains(.secondary) == true ? 3 : 1
                pressedPointerButton = button
                lastHoverLocation = touch.location(in: self)
                inputHandler?.sendMouseButton(down: true, button: button)
            case .moved:
                let previous = lastHoverLocation ?? touch.previousLocation(in: self)
                let location = touch.location(in: self)
                lastHoverLocation = location
                forwardPointerDelta(from: previous, to: location)
            case .ended:
                if let button = pressedPointerButton {
                    inputHandler?.sendMouseButton(down: false, button: button)
                }
                pressedPointerButton = nil
            }
            return true
        }

        private func forwardPointerDelta(from previous: CGPoint, to location: CGPoint) {
            let dx = Int16(clamping: Int(((location.x - previous.x) * Self.pointerSensitivity).rounded()))
            let dy = Int16(clamping: Int(((location.y - previous.y) * Self.pointerSensitivity).rounded()))
            guard dx != 0 || dy != 0 else { return }
            inputHandler?.sendMouseMove(dx: dx, dy: dy)
        }
    #endif

    private var remoteMouseInputEnabled: Bool {
        !gamepadModeActive && !overlayVisible
    }

    private func clearRemoteTouchTracking() {
        activeRemoteTouch = nil
        lastRemoteTouchLocation = nil
    }

    private func cancelRemoteMouseTracking() {
        clearRemoteTouchTracking()
        if remoteSelectMouseDown {
            inputHandler?.sendMouseButton(down: false, button: 1)
            remoteSelectMouseDown = false
        }
    }
}

// MARK: - WebRTC Video Renderer

/// Implements LKRTCVideoRenderer to receive decoded WebRTC frames and feed them
/// to the display layer's background-safe AVSampleBufferVideoRenderer.
private final nonisolated class WebRTCFrameRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private struct PendingFrame: @unchecked Sendable {
        let frame: LKRTCVideoFrame
        let trace: VideoFrameTrace?
        let arrivalTime: TimeInterval
    }

    private enum DrainAction {
        case idle
        case wait(TimeInterval)
        case process(PendingFrame, UInt64)
    }

    private struct State: @unchecked Sendable {
        var inspectionCache = DecodedVideoFormatInspectionCache()
        var decodedFormatSignature: VideoFormatSignature?
        var mailbox = LatestFrameMailbox<PendingFrame>()
        var drainSchedule = VideoRendererDrainSchedule()
        var isFlushing = false
        var generation: UInt64 = 0
        var metricsRequestInFlight = false
        var activeEnqueues = 0
        var flushPlan = VideoRendererFlushPlan()
        var pacer: AdaptiveFramePacer?
        var pacingSize: CGSize?
        var pendingDeadline: TimeInterval?
    }

    var sampleBufferRenderer: AVSampleBufferVideoRenderer?
    var onDecodedVideoFormatChanged: (@Sendable (DecodedVideoFormat) -> Void)?
    private let diagnostics: VideoPipelineDiagnostics
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let i420Converter = I420FrameConverter()
    private let renderQueue = DispatchQueue(
        label: "com.owenselles.CloudNow2.video-frame-renderer",
        qos: .userInteractive
    )

    init(diagnostics: VideoPipelineDiagnostics) {
        self.diagnostics = diagnostics
    }

    func setSize(_: CGSize) {}

    func setAdaptiveFramePacing(_ enabled: Bool, frameRate: Int) {
        let pacer = enabled ? AdaptiveFramePacer(frameRate: frameRate) : nil
        let identifier = state.withLock { state -> UInt64? in
            guard state.pacer?.frameRate != pacer?.frameRate else { return nil }
            state.pacer = pacer
            state.pacingSize = nil
            state.pendingDeadline = nil
            state.generation &+= 1
            state.drainSchedule.finish()
            guard !state.isFlushing, state.mailbox.hasPending else { return nil }
            _ = state.drainSchedule.beginIfNeeded()
            return state.drainSchedule.identifier
        }
        if let identifier {
            scheduleDrain(identifier)
        }
    }

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame, let sampleBufferRenderer else { return }
        let trace = diagnostics.beginFrame()

        if sampleBufferRenderer.status == .failed || sampleBufferRenderer.requiresFlushToResumeDecoding {
            recoverAfterFailure()
            diagnostics.recordDrop(trace)
            return
        }

        let pendingFrame = PendingFrame(frame: frame, trace: trace, arrivalTime: Self.now)
        let submission = state.withLock { state -> (PendingFrame?, UInt64?) in
            guard !state.isFlushing else { return (pendingFrame, nil) }
            if state.pacer?.observe(
                timestamp: UInt32(bitPattern: frame.timeStamp),
                arrivalTime: pendingFrame.arrivalTime
            ) == true {
                state.generation &+= 1
                state.pendingDeadline = nil
                state.drainSchedule.finish()
            }
            switch state.mailbox.store(pendingFrame) {
            case let .stored(replacing: replaced):
                let shouldSchedule = state.drainSchedule.beginIfNeeded()
                return (replaced, shouldSchedule ? state.drainSchedule.identifier : nil)
            case let .rejected(rejected):
                return (rejected, nil)
            }
        }
        if let dropped = submission.0 {
            diagnostics.recordDrop(dropped.trace)
        }
        if let identifier = submission.1 {
            scheduleDrain(identifier)
        }
    }

    private static var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func scheduleDrain(_ identifier: UInt64, deadline: TimeInterval? = nil) {
        let work: @Sendable () -> Void = { [weak self] in
            self?.drainPendingFrames(identifier: identifier)
        }
        if let deadline {
            renderQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: UInt64(deadline * 1_000_000_000)), execute: work)
        } else {
            renderQueue.async(execute: work)
        }
    }

    private func drainPendingFrames(identifier: UInt64) {
        while let sampleBufferRenderer {
            guard state.withLock({ $0.drainSchedule.isCurrent(identifier) }) else { return }
            if sampleBufferRenderer.status == .failed || sampleBufferRenderer.requiresFlushToResumeDecoding {
                recoverAfterFailure()
                return
            }
            switch nextDrainAction(identifier: identifier) {
            case .idle:
                return
            case let .wait(deadline):
                scheduleDrain(identifier, deadline: deadline)
                return
            case let .process(frame, generation):
                process(frame, generation: generation, renderer: sampleBufferRenderer)
            }
        }
        dropPendingFrame()
    }

    private func nextDrainAction(identifier: UInt64) -> DrainAction {
        state.withLock { state in
            guard state.drainSchedule.isCurrent(identifier) else { return .idle }
            guard !state.isFlushing, let pending = state.mailbox.take() else {
                state.drainSchedule.finish()
                return .idle
            }
            if var pacer = state.pacer {
                let size = CGSize(width: Int(pending.frame.width), height: Int(pending.frame.height))
                if state.pacingSize != size {
                    pacer.reset()
                    state.pacingSize = size
                    state.pendingDeadline = nil
                }
                let now = Self.now
                let timestamp = UInt32(bitPattern: pending.frame.timeStamp)
                let deadline = state.pendingDeadline ?? pacer.deadline(
                    timestamp: timestamp, arrivalTime: pending.arrivalTime, now: now
                )
                if deadline > now {
                    // Keep this deadline when newer arrivals replace the mailbox, avoiding starvation.
                    state.pendingDeadline = deadline
                    state.pacer = pacer
                    _ = state.mailbox.storeIfEmpty(pending)
                    return .wait(deadline)
                }
                pacer.didSubmit(timestamp: timestamp, deadline: deadline)
                state.pacer = pacer
                state.pendingDeadline = nil
            }
            return .process(pending, state.generation)
        }
    }

    private func process(
        _ pendingFrame: PendingFrame,
        generation renderGeneration: UInt64,
        renderer sampleBufferRenderer: AVSampleBufferVideoRenderer
    ) {
        let frame = pendingFrame.frame
        let trace = pendingFrame.trace

        // Hardware-decoded H.264/H.265/AV1 frames arrive as CVPixelBuffer (NV12/420v).
        // H.265/HDR/AV1 can fall back to software decoding (LKRTCI420Buffer) on some
        // hardware — convert to a planar CVPixelBuffer so the display layer can render it.
        let cvBuf: CVPixelBuffer
        let decoderPath: VideoDecoderPath
        if let hwBuf = frame.buffer as? LKRTCCVPixelBuffer {
            cvBuf = hwBuf.pixelBuffer
            decoderPath = .hardware
        } else if let i420 = frame.buffer as? LKRTCI420Buffer {
            let conversionStart = diagnostics.beginConversion(trace)
            guard let converted = i420Converter.convert(i420) else {
                diagnostics.cancelConversion(trace)
                diagnostics.recordDrop(trace)
                return
            }
            diagnostics.endConversion(trace, startedAt: conversionStart)
            cvBuf = converted
            decoderPath = .softwareI420
        } else {
            videoLog.warning("[WebRTCFrameRenderer] Unhandled frame type: \(String(describing: type(of: frame.buffer)), privacy: .public)")
            diagnostics.recordDrop(trace)
            return
        }

        var inspectionCache = state.withLock { $0.inspectionCache }
        guard let inspection = inspectionCache.resolve(
            pixelBuffer: cvBuf,
            decoderPath: decoderPath
        ) else {
            diagnostics.recordDrop(trace)
            return
        }
        let updatedInspectionCache = inspectionCache
        let decodedSignature = DecodedVideoFormatInspector.signature(for: inspection.format)
        let cacheCommit = state.withLock { state -> (Bool, Bool) in
            guard !state.isFlushing, state.generation == renderGeneration else {
                return (false, false)
            }
            state.inspectionCache = updatedInspectionCache
            guard state.decodedFormatSignature != decodedSignature else { return (true, false) }
            if state.decodedFormatSignature != nil {
                state.pacer?.reset()
            }
            state.decodedFormatSignature = decodedSignature
            return (true, true)
        }
        guard cacheCommit.0 else {
            diagnostics.recordDrop(trace)
            return
        }
        if cacheCommit.1 {
            diagnostics.updateDecodedVideoFormat(inspection.format)
            onDecodedVideoFormatChanged?(inspection.format)
        }

        let sampleCreationStart = diagnostics.beginSampleCreation(trace)

        // DisplayImmediately makes the timestamp irrelevant and replaces queued stale images.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: cvBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: inspection.formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else {
            diagnostics.endSampleCreation(trace, startedAt: sampleCreationStart)
            diagnostics.recordDrop(trace)
            return
        }
        markForImmediatePresentation(sampleBuffer)
        diagnostics.endSampleCreation(trace, startedAt: sampleCreationStart)

        // This is a real-time producer. AVFoundation documents readiness as a
        // backpressure hint; waiting for its callback can permanently stall a
        // live stream on tvOS, while enqueueing remains safe.
        if !sampleBufferRenderer.isReadyForMoreMediaData {
            diagnostics.recordBackpressure()
        }
        let didBeginEnqueue = state.withLock { state -> Bool in
            guard !state.isFlushing, state.generation == renderGeneration else { return false }
            state.activeEnqueues += 1
            return true
        }
        guard didBeginEnqueue else {
            diagnostics.recordDrop(trace)
            return
        }

        sampleBufferRenderer.enqueue(sampleBuffer)
        let pendingFlush = state.withLock { state -> VideoRendererFlushRequest? in
            state.activeEnqueues -= 1
            guard state.activeEnqueues == 0 else { return nil }
            return state.flushPlan.activatePendingAfterEnqueuesDrain()
        }
        diagnostics.recordEnqueue(trace)
        if let pendingFlush {
            performFlush(pendingFlush)
        }
    }

    func reset(preservingDisplayedImage: Bool) {
        flush(preservingDisplayedImage: preservingDisplayedImage, recordFailure: false)
    }

    func teardown() {
        let result = state.withLock { state -> (VideoRendererFlushRequest?, PendingFrame?) in
            guard !state.mailbox.isTerminated else { return (nil, nil) }
            state.generation &+= 1
            state.isFlushing = true
            state.inspectionCache.reset()
            state.decodedFormatSignature = nil
            state.drainSchedule.finish()
            state.pacer?.reset()
            state.pendingDeadline = nil
            state.pacingSize = nil
            let request = VideoRendererFlushRequest(
                generation: state.generation,
                removeDisplayedImage: true
            )
            let requestToRun = state.flushPlan.upgradeToTerminal(
                request,
                activeEnqueues: state.activeEnqueues
            )
            return (requestToRun, state.mailbox.teardown())
        }
        if let dropped = result.1 {
            diagnostics.recordDrop(dropped.trace)
        }
        if let requestToRun = result.0 {
            performFlush(requestToRun)
        }
    }

    func recoverAfterFailure() {
        flush(preservingDisplayedImage: true, recordFailure: true)
    }

    func recoverIfRequired() {
        guard let sampleBufferRenderer,
              sampleBufferRenderer.status == .failed || sampleBufferRenderer.requiresFlushToResumeDecoding
        else {
            return
        }
        recoverAfterFailure()
    }

    func capturePerformanceMetrics(completion: @escaping @Sendable () -> Void) {
        guard let sampleBufferRenderer else {
            completion()
            return
        }
        let shouldRequest = state.withLock { state -> Bool in
            guard !state.metricsRequestInFlight else { return false }
            state.metricsRequestInFlight = true
            return true
        }
        guard shouldRequest else {
            return
        }
        sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self, weak diagnostics] metrics in
            if let metrics {
                diagnostics?.updateAVMetrics(
                    totalFrames: metrics.totalNumberOfFrames,
                    droppedFrames: metrics.numberOfDroppedFrames,
                    corruptedFrames: metrics.numberOfCorruptedFrames,
                    accumulatedFrameDelaySeconds: metrics.totalAccumulatedFrameDelay
                )
            }
            self?.state.withLock { $0.metricsRequestInFlight = false }
            completion()
        }
    }

    private func flush(preservingDisplayedImage: Bool, recordFailure: Bool) {
        guard sampleBufferRenderer != nil else { return }
        let result = state.withLock { state -> (Bool, VideoRendererFlushRequest?, PendingFrame?) in
            guard !state.isFlushing, !state.mailbox.isTerminated else {
                return (false, nil, nil)
            }
            state.isFlushing = true
            state.generation &+= 1
            state.inspectionCache.reset()
            state.decodedFormatSignature = nil
            state.drainSchedule.finish()
            state.pacer?.reset()
            state.pendingDeadline = nil
            state.pacingSize = nil
            let dropped = state.mailbox.flush()
            let request = VideoRendererFlushRequest(
                generation: state.generation,
                removeDisplayedImage: !preservingDisplayedImage
            )
            let requestToRun = state.flushPlan.begin(
                request,
                activeEnqueues: state.activeEnqueues
            )
            return (true, requestToRun, dropped)
        }
        guard result.0 else { return }

        if let dropped = result.2 {
            diagnostics.recordDrop(dropped.trace)
        }

        if recordFailure {
            diagnostics.recordRendererFailure()
        }
        if let requestToRun = result.1 {
            performFlush(requestToRun)
        }
    }

    private func performFlush(_ request: VideoRendererFlushRequest) {
        guard let sampleBufferRenderer else {
            if let followUp = completeFlush(request) {
                performFlush(followUp)
            }
            return
        }
        sampleBufferRenderer.flush(removingDisplayedImage: request.removeDisplayedImage) { [weak self] in
            guard let self else { return }
            let followUp = completeFlush(request)
            diagnostics.recordRendererFlush()
            if let followUp {
                performFlush(followUp)
            }
        }
    }

    private func completeFlush(_ request: VideoRendererFlushRequest) -> VideoRendererFlushRequest? {
        state.withLock { state -> VideoRendererFlushRequest? in
            switch state.flushPlan.complete(request) {
            case .ignored:
                return nil
            case .finished:
                state.isFlushing = false
                return nil
            case let .followUp(followUp):
                return followUp
            }
        }
    }

    private func dropPendingFrame() {
        let dropped = state.withLock { state -> PendingFrame? in
            state.drainSchedule.finish()
            return state.mailbox.flush()
        }
        if let dropped {
            diagnostics.recordDrop(dropped.trace)
        }
    }

    private func markForImmediatePresentation(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }

        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

// MARK: - Streaming View Controller

import GameController

/// GCEventViewController subclass whose view IS the VideoSurfaceView.
/// controllerUserInteractionEnabled is toggled dynamically: false during streaming
/// (prevents O/Circle → system back) and true when the pause overlay is open
/// (allows D-pad to navigate SwiftUI overlay buttons via the focus engine).
final class StreamingViewController: GCEventViewController {
    let videoSurface = VideoSurfaceView()

    override func loadView() {
        controllerUserInteractionEnabled = false
        view = videoSurface
    }

    #if os(iOS)
        /// iPadOS: during gameplay the game draws its own cursor, so the system
        /// pointer is hidden over the video (it comes back in the pause menu). It
        /// is deliberately not locked, so a Universal Control pointer can still
        /// leave the iPad for the Mac at the screen edge.
        var capturesPointer = true {
            didSet {
                guard capturesPointer != oldValue else { return }
                pointerInteraction.invalidate()
                setNeedsUpdateOfPrefersPointerLocked()
            }
        }

        private lazy var pointerInteraction = UIPointerInteraction(delegate: self)

        /// On the Mac the mouse or trackpad belongs to the game while playing
        /// (raw GCMouse deltas, cursor locked), as an FPS needs; ⌘⇧M or the
        /// controller's PS button opens the menu, which releases it. On iPad the
        /// pointer stays unlocked so Universal Control can leave for the Mac.
        override var prefersPointerLocked: Bool {
            #if targetEnvironment(macCatalyst)
                capturesPointer
            #else
                false
            #endif
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            videoSurface.addInteraction(pointerInteraction)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setNeedsUpdateOfPrefersPointerLocked()
        }
    #endif
}

#if os(iOS)
    extension StreamingViewController: UIPointerInteractionDelegate {
        func pointerInteraction(
            _: UIPointerInteraction,
            styleFor _: UIPointerRegion
        ) -> UIPointerStyle? {
            capturesPointer ? .hidden() : nil
        }
    }
#endif

// MARK: - SwiftUI Wrapper

import SwiftUI

struct VideoSurfaceViewRepresentable: UIViewControllerRepresentable {
    let streamController: GFNStreamController
    var showOverlay: Bool = false

    func makeUIViewController(context _: Context) -> StreamingViewController {
        let vc = StreamingViewController()
        Task { @MainActor in
            streamController.bindVideoView(vc.videoSurface)
        }
        return vc
    }

    func updateUIViewController(_ vc: StreamingViewController, context _: Context) {
        vc.videoSurface.videoTrack = streamController.videoTrack
        // Route controller input to the GameController layer during gameplay so the
        // overlay trigger button can be sampled. Switch to the responder chain only
        // while the overlay is visible so SwiftUI focus navigation works there.
        vc.controllerUserInteractionEnabled = showOverlay
        vc.videoSurface.overlayVisible = showOverlay
        #if os(iOS)
            vc.capturesPointer = !showOverlay
        #endif
    }

    static func dismantleUIViewController(_ vc: StreamingViewController, coordinator _: ()) {
        vc.videoSurface.prepareForDismantle()
    }
}
