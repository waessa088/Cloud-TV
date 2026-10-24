import SwiftUI

/// In-stream pause menu for GeForce NOW, in Liquid Glass: the game stays visible
/// behind a light dim, with large glass cards for the main actions.
struct GlassPauseMenu: View {
    struct HandoffTarget: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let isBusy: Bool
        let action: () -> Void
    }

    let gameTitle: String
    let stats: StreamStats
    let remainingMinutes: Int?
    let statsModeLabel: String
    let handoffTargets: [HandoffTarget]
    let handoffError: String?
    let remoteModeLabel: String?
    let remoteModeIcon: String
    let isEndDisabled: Bool
    let onResume: () -> Void
    let onCycleStatistics: () -> Void
    let onToggleRemoteMode: () -> Void
    let onLeave: () -> Void
    let onEndRequest: () -> Void

    @FocusState private var focusedCard: Card?

    private enum Card: Hashable {
        case resume
        case handoff(String)
        case statistics
        case home
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: Metrics.sectionGap)
                cards
                    .padding(.bottom, Metrics.sectionGap)
                footer
            }
            .padding(.horizontal, Metrics.outerHorizontal)
            .padding(.vertical, Metrics.outerVertical)
        }
        .foregroundStyle(.white)
        .defaultFocus($focusedCard, .resume)
        .onAppear { focusedCard = .resume }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Metrics.headerSpacing) {
                Text(PauseMenuText.paused)
                    .font(.system(size: Metrics.eyebrowSize, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.72))
                Text(gameTitle)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !qualityChips.isEmpty {
                    HStack(spacing: Metrics.chipSpacing) {
                        ForEach(qualityChips, id: \.text) { chip in
                            Text(chip.text)
                                .font(.system(size: Metrics.chipSize, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(chip.tint ?? .white)
                                .padding(.horizontal, Metrics.chipHorizontal)
                                .padding(.vertical, Metrics.chipVertical)
                                .glassEffect(
                                    chip.tint.map { .regular.tint($0.opacity(0.25)) } ?? .regular,
                                    in: .capsule
                                )
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 24)
            if let remainingMinutes {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(PauseMenuText.timeLeft)
                        .font(.system(size: Metrics.eyebrowSize))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(Self.duration(remainingMinutes))
                        .font(.system(size: Metrics.timeSize, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(remainingMinutes < 30 ? .orange : .white)
                }
            }
        }
    }

    private struct Chip {
        let text: String
        let tint: Color?
    }

    private var qualityChips: [Chip] {
        var chips: [Chip] = []
        if stats.resolutionWidth > 0 {
            let fps = stats.fps > 0 ? " · \(Int(stats.fps.rounded())) i/s" : ""
            chips.append(Chip(text: "\(stats.resolutionWidth) × \(stats.resolutionHeight)\(fps)", tint: nil))
        }
        if !stats.codec.isEmpty {
            chips.append(Chip(text: stats.codec.uppercased(), tint: nil))
        }
        if stats.rttMs > 0 {
            let latency = Int(stats.rttMs.rounded())
            let tint: Color = latency <= 40 ? .green : (latency <= 80 ? .yellow : .orange)
            chips.append(Chip(text: "\(latency) ms", tint: tint))
        }
        return chips
    }

    // MARK: Cards

    private var cards: some View {
        GlassEffectContainer(spacing: Metrics.cardSpacing) {
            HStack(spacing: Metrics.cardSpacing) {
                GlassMenuCard(
                    title: PauseMenuText.resume,
                    subtitle: PauseMenuText.backToGame,
                    systemImage: "play.fill",
                    isProminent: true,
                    action: onResume
                )
                .focused($focusedCard, equals: .resume)
                .accessibilityIdentifier("stream.pause.resume")

                ForEach(handoffTargets) { target in
                    GlassMenuCard(
                        title: target.title,
                        subtitle: target.isBusy ? HandoffText.sending : target.subtitle,
                        systemImage: target.systemImage,
                        action: target.action
                    )
                    .disabled(target.isBusy)
                    .focused($focusedCard, equals: .handoff(target.id))
                    .accessibilityIdentifier("stream.pause.handoff")
                }

                GlassMenuCard(
                    title: PauseMenuText.statistics,
                    subtitle: statsModeLabel,
                    systemImage: "chart.xyaxis.line",
                    action: onCycleStatistics
                )
                .focused($focusedCard, equals: .statistics)
                .accessibilityIdentifier("stream.pause.statistics")

                GlassMenuCard(
                    title: PauseMenuText.home,
                    subtitle: PauseMenuText.gameStaysOpen,
                    systemImage: "house",
                    action: onLeave
                )
                .focused($focusedCard, equals: .home)
                .accessibilityIdentifier("stream.pause.leave")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Metrics.chipSpacing) {
            HStack(spacing: Metrics.hintSpacing) {
                ForEach(PauseMenuText.hints, id: \.label) { hint in
                    HStack(spacing: 8) {
                        Text(hint.key)
                            .font(.system(size: Metrics.hintSize, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                            )
                        Text(hint.label)
                            .font(.system(size: Metrics.hintSize))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
            .padding(.horizontal, Metrics.chipHorizontal * 1.5)
            .padding(.vertical, Metrics.chipVertical * 1.5)
            .glassEffect(.regular, in: .capsule)

            if let handoffError {
                Text(handoffError)
                    .font(.system(size: Metrics.hintSize))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            if let remoteModeLabel {
                Button(action: onToggleRemoteMode) {
                    Label(remoteModeLabel, systemImage: remoteModeIcon)
                        .font(.system(size: Metrics.hintSize, weight: .semibold))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("stream.pause.remote-mode")
            }

            Button(role: .destructive, action: onEndRequest) {
                Label(PauseMenuText.endSession, systemImage: "xmark.circle")
                    .font(.system(size: Metrics.hintSize, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
            }
            .buttonStyle(.glass)
            .disabled(isEndDisabled)
            .accessibilityIdentifier("stream.pause.end-session")
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// One large glass action card.
private struct GlassMenuCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: Metrics.cardIconSize, weight: .semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                Text(title)
                    .font(.system(size: Metrics.cardTitleSize, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: Metrics.cardSubtitleSize))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Metrics.cardHeight, maxHeight: Metrics.cardHeight, alignment: .leading)
            .padding(Metrics.cardPadding)
            .contentShape(.rect(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: Metrics.cardRadius))
        .tint(isProminent ? .white.opacity(0.28) : nil)
    }
}

/// Sizes for the TV (10-foot) and the iPad (arm's length).
private enum Metrics {
    #if os(tvOS)
        static let outerHorizontal: CGFloat = 90
        static let outerVertical: CGFloat = 70
        static let sectionGap: CGFloat = 34
        static let headerSpacing: CGFloat = 12
        static let eyebrowSize: CGFloat = 22
        static let titleSize: CGFloat = 64
        static let timeSize: CGFloat = 34
        static let chipSize: CGFloat = 22
        static let chipSpacing: CGFloat = 12
        static let chipHorizontal: CGFloat = 18
        static let chipVertical: CGFloat = 9
        static let cardSpacing: CGFloat = 36
        static let cardHeight: CGFloat = 200
        static let cardPadding: CGFloat = 34
        static let cardRadius: CGFloat = 36
        static let cardIconSize: CGFloat = 46
        static let cardTitleSize: CGFloat = 34
        static let cardSubtitleSize: CGFloat = 23
        static let hintSize: CGFloat = 22
        static let hintSpacing: CGFloat = 30
    #else
        static let outerHorizontal: CGFloat = 56
        static let outerVertical: CGFloat = 44
        static let sectionGap: CGFloat = 20
        static let headerSpacing: CGFloat = 8
        static let eyebrowSize: CGFloat = 13
        static let titleSize: CGFloat = 40
        static let timeSize: CGFloat = 22
        static let chipSize: CGFloat = 14
        static let chipSpacing: CGFloat = 8
        static let chipHorizontal: CGFloat = 12
        static let chipVertical: CGFloat = 6
        static let cardSpacing: CGFloat = 20
        static let cardHeight: CGFloat = 128
        static let cardPadding: CGFloat = 22
        static let cardRadius: CGFloat = 28
        static let cardIconSize: CGFloat = 30
        static let cardTitleSize: CGFloat = 21
        static let cardSubtitleSize: CGFloat = 14
        static let hintSize: CGFloat = 14
        static let hintSpacing: CGFloat = 20
    #endif
}

/// French / English copy for the pause menu, kept beside the handoff strings.
enum PauseMenuText {
    private static var isFrench: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("fr")
    }

    static var paused: String {
        isFrench ? "En pause" : "Paused"
    }

    static var timeLeft: String {
        isFrench ? "Temps restant" : "Time left"
    }

    static var resume: String {
        isFrench ? "Reprendre" : "Resume"
    }

    static var backToGame: String {
        isFrench ? "Retour au jeu" : "Back to the game"
    }

    static var statistics: String {
        isFrench ? "Statistiques" : "Statistics"
    }

    static var home: String {
        isFrench ? "Accueil" : "Home"
    }

    static var gameStaysOpen: String {
        isFrench ? "La partie reste ouverte" : "The game stays open"
    }

    static var endSession: String {
        isFrench ? "Terminer la session" : "End session"
    }

    struct Hint {
        let key: String
        let label: String
    }

    static var hints: [Hint] {
        #if os(tvOS)
            [
                Hint(key: "Menu", label: isFrench ? "Fermer" : "Close"),
                Hint(key: "A", label: isFrench ? "Valider" : "Select"),
            ]
        #else
            [
                Hint(key: "PS", label: isFrench ? "Fermer le menu" : "Close menu"),
            ]
        #endif
    }
}
