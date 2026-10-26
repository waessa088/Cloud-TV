import GameController
import SwiftUI

/// The "Manette" screen: routing mode, connected controller, link state,
/// relay latency, and a live button and stick test.
struct ControllerPanelView: View {
    var onClose: (() -> Void)?

    @State private var mode = ControllerMode.load()
    @State private var controllerName: String?
    @State private var controllerCategory: String?
    @State private var batteryText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                HStack {
                    Text(ControllerText.title)
                        .font(.system(size: Metrics.titleSize, weight: .bold))
                    Spacer()
                    if let onClose {
                        Button(ControllerText.done, action: onClose)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("controller.close")
                    }
                }

                section(ControllerText.modeSection) {
                    VStack(spacing: Metrics.rowSpacing) {
                        ForEach(ControllerMode.allCases, id: \.self) { option in
                            modeRow(option)
                        }
                    }
                }

                section(ControllerText.deviceSection) {
                    deviceSummary
                }

                section(ControllerText.stateSection) {
                    connectionState
                }

                if HandoffDeviceKind.current.canRelayController {
                    section(ControllerText.latencySection) {
                        latencySummary
                    }
                }

                section(ControllerText.testSection) {
                    ControllerTestView()
                }

                section(ControllerText.pairingSection) {
                    Text(ControllerText.pairingSteps)
                        .font(.system(size: Metrics.bodySize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Metrics.outerPadding)
        }
        .onChange(of: mode) { _, newValue in newValue.save() }
        .task { await refreshDevice() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            Task { await refreshDevice() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            Task { await refreshDevice() }
        }
        .accessibilityIdentifier("controller-screen")
    }

    // MARK: Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text(title)
                .font(.system(size: Metrics.sectionTitleSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
                .padding(Metrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
        }
    }

    private func modeRow(_ option: ControllerMode) -> some View {
        Button {
            mode = option
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: mode == option ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Metrics.bodySize + 4))
                    .foregroundStyle(mode == option ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ControllerText.title(option))
                        .font(.system(size: Metrics.bodySize, weight: .semibold))
                    Text(ControllerText.detail(option))
                        .font(.system(size: Metrics.captionSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == option ? .isSelected : [])
        .accessibilityIdentifier("controller.mode.\(option.rawValue)")
    }

    private var deviceSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let controllerName {
                Text(controllerName)
                    .font(.system(size: Metrics.bodySize, weight: .semibold))
                if let controllerCategory, controllerCategory != controllerName {
                    Text(controllerCategory)
                        .font(.system(size: Metrics.captionSize))
                        .foregroundStyle(.secondary)
                }
                if let batteryText {
                    Label(batteryText, systemImage: "battery.75percent")
                        .font(.system(size: Metrics.captionSize))
                }
                Text(ControllerText.transportNote)
                    .font(.system(size: Metrics.captionSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ControllerText.noController)
                    .font(.system(size: Metrics.bodySize, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var connectionState: some View {
        let handoff = HandoffService.shared
        let text: String
        let color: Color
        if handoff.relay != nil {
            let status = handoff.relayStatus
            if !status.acknowledged {
                text = ControllerText.relayWaiting
                color = .yellow
            } else if status.relayInUse {
                text = ControllerText.relayActive
                color = .green
            } else {
                text = ControllerText.relaySuspended
                color = .blue
            }
        } else if RemoteGamepadInbox.shared.relayInUse {
            text = ControllerText.receivingRelay
            color = .green
        } else if controllerName != nil {
            text = ControllerText.localActive
            color = .green
        } else {
            text = ControllerText.needsPairing
            color = .orange
        }
        return Label {
            Text(text)
                .font(.system(size: Metrics.bodySize))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Circle().fill(color).frame(width: 12, height: 12)
        }
        .accessibilityIdentifier("controller.state")
    }

    private var latencySummary: some View {
        let stats = HandoffService.shared.relayStatus.latency
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Metrics.rowSpacing * 2) {
                latencyValue(ControllerText.median, LatencyStats.milliseconds(stats.median))
                latencyValue("P95", LatencyStats.milliseconds(stats.p95))
                latencyValue("P99", LatencyStats.milliseconds(stats.p99))
            }
            Text(ControllerText.latencyNote(samples: stats.count))
                .font(.system(size: Metrics.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("controller.latency")
    }

    private func latencyValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: Metrics.captionSize))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: Metrics.bodySize + 4, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func refreshDevice() async {
        let controller = LocalGamepadSampler.preferredController()
        controllerName = controller?.vendorName
        controllerCategory = controller?.productCategory
        if let battery = controller?.battery {
            let percent = Int((battery.batteryLevel * 100).rounded())
            batteryText = battery.batteryState == .charging
                ? ControllerText.charging(percent)
                : "\(percent) %"
        } else {
            batteryText = nil
        }
    }
}

/// Live readout of the connected controller: sticks, triggers and buttons,
/// read straight from GameController each frame (no handlers, so it never
/// interferes with the stream's own input).
struct ControllerTestView: View {
    var body: some View {
        TimelineView(.animation) { _ in
            let pad = LocalGamepadSampler.preferredController()?.extendedGamepad
            if let pad {
                HStack(alignment: .center, spacing: 28) {
                    StickDot(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value, label: "L")
                    TriggerBar(value: pad.leftTrigger.value, label: "L2")
                    ButtonGrid(pad: pad)
                    TriggerBar(value: pad.rightTrigger.value, label: "R2")
                    StickDot(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value, label: "R")
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(ControllerText.noController)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("controller.test")
    }
}

private struct StickDot: View {
    let x: Float
    let y: Float
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(x) * 38, y: CGFloat(-y) * 38)
            }
            .frame(width: 90, height: 90)
            Text("\(label) \(String(format: "%+.2f %+.2f", x, y))")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TriggerBar: View {
    let value: Float
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(.white)
                    .frame(height: 90 * CGFloat(value))
            }
            .frame(width: 14, height: 90)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ButtonGrid: View {
    let pad: GCExtendedGamepad

    private var buttons: [(String, Bool)] {
        [
            ("△", pad.buttonY.isPressed), ("○", pad.buttonB.isPressed),
            ("✕", pad.buttonA.isPressed), ("□", pad.buttonX.isPressed),
            ("L1", pad.leftShoulder.isPressed), ("R1", pad.rightShoulder.isPressed),
            ("L3", pad.leftThumbstickButton?.isPressed ?? false),
            ("R3", pad.rightThumbstickButton?.isPressed ?? false),
            ("↑", pad.dpad.up.isPressed), ("↓", pad.dpad.down.isPressed),
            ("←", pad.dpad.left.isPressed), ("→", pad.dpad.right.isPressed),
            ("Share", pad.buttonOptions?.isPressed ?? false),
            ("Options", pad.buttonMenu.isPressed),
            ("PS", pad.buttonHome?.isPressed ?? false),
        ]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 4), spacing: 6) {
            ForEach(buttons, id: \.0) { name, pressed in
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 64, height: 30)
                    .background(pressed ? Color.white : Color.white.opacity(0.1), in: .capsule)
                    .foregroundStyle(pressed ? Color.black : Color.white)
            }
        }
        .frame(maxWidth: 280)
    }
}

private enum Metrics {
    #if os(tvOS)
        static let outerPadding: CGFloat = 80
        static let sectionSpacing: CGFloat = 40
        static let rowSpacing: CGFloat = 14
        static let titleSize: CGFloat = 52
        static let sectionTitleSize: CGFloat = 22
        static let bodySize: CGFloat = 28
        static let captionSize: CGFloat = 22
        static let cardPadding: CGFloat = 30
        static let cardRadius: CGFloat = 30
    #else
        static let outerPadding: CGFloat = 40
        static let sectionSpacing: CGFloat = 26
        static let rowSpacing: CGFloat = 10
        static let titleSize: CGFloat = 34
        static let sectionTitleSize: CGFloat = 13
        static let bodySize: CGFloat = 17
        static let captionSize: CGFloat = 13
        static let cardPadding: CGFloat = 18
        static let cardRadius: CGFloat = 22
    #endif
}
