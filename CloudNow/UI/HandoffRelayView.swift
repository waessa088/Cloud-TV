import SwiftUI

/// Shown on the iPad while its controller drives a game on the Apple TV. Kept
/// dark and still, since the iPad typically sits aside while the TV plays.
struct HandoffRelayView: View {
    let relay: HandoffService.RelayState
    let onResumeHere: () -> Void
    let onStop: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                HStack(spacing: 18) {
                    Image(systemName: "gamecontroller.fill")
                    Image(systemName: "arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "appletv.fill")
                }
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text(HandoffText.relayTitle)
                        .font(.title.weight(.semibold))
                    Text(relay.game.title)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Text(HandoffText.relayDetail(controller: relay.controllerName))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 520)

                Label(HandoffText.relayMenuHint, systemImage: "house")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))

                relayLink

                VStack(spacing: 12) {
                    Button(action: onResumeHere) {
                        Label(HandoffText.resumeHere, systemImage: "ipad.landscape")
                            .frame(maxWidth: 360)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("handoff-relay.resume-here")

                    Button(HandoffText.stopRelay, action: onStop)
                        .buttonStyle(.bordered)
                        .tint(.gray)
                        .accessibilityIdentifier("handoff-relay.stop")
                }
                .padding(.top, 12)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .preferredColorScheme(.dark)
        .immersiveOnIPad()
    }

    /// Link state and measured relay latency, refreshed a few times a second.
    private var relayLink: some View {
        let status = HandoffService.shared.relayStatus
        let text = !status.acknowledged
            ? ControllerText.relayWaiting
            : (status.relayInUse ? ControllerText.relayActive : ControllerText.relaySuspended)
        return VStack(spacing: 8) {
            Text(text)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
            if status.relayInUse, status.latency.count > 0 {
                Text("\(ControllerText.median) \(LatencyStats.milliseconds(status.latency.median)) · P95 \(LatencyStats.milliseconds(status.latency.p95)) · P99 \(LatencyStats.milliseconds(status.latency.p99))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 560)
        .accessibilityIdentifier("handoff-relay.status")
    }
}
