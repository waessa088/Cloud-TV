import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(CloudSessionCoordinator.self) private var cloudSessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: GamesViewModel
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil
    @State private var selectedTab: AppTab = .home
    @State private var controllerNavigation = UIControllerNavigationCoordinator()
    @State private var handoffStatus: String?
    private let loadsRemoteData: Bool

    init(
        viewModel: GamesViewModel = GamesViewModel(),
        loadsRemoteData: Bool = true
    ) {
        _viewModel = State(initialValue: viewModel)
        self.loadsRemoteData = loadsRemoteData
    }

    var body: some View {
        CloudNowTabShell(
            selection: $selectedTab,
            controllerNavigation: controllerNavigation,
            accessibilityIdentifier: "main-navigation",
            modeLifecycle: viewModel
        ) {
            Tab(L10n.text("home"), systemImage: "house.fill", value: AppTab.home) {
                HomeView(
                    onPlay: { game in
                        directSessionToResume = nil
                        sessionToResume = viewModel.activeSessions.first { session in
                            game.variants.contains { v in
                                guard let appId = v.appId, let sessionAppId = session.appId else { return false }
                                return appId == sessionAppId
                            }
                        }
                        gameToPlay = game
                    },
                    onResume: { rs in
                        directSessionToResume = rs.session
                        sessionToResume = nil
                        gameToPlay = rs.game
                    }
                )
                .accessibilityIdentifier("home-screen")
            }
            Tab(L10n.text("library"), systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView(onPlay: { gameToPlay = $0 })
                    .accessibilityIdentifier("library-screen")
            }
            Tab(L10n.text("store"), systemImage: "bag.fill", value: AppTab.store) {
                StoreView(onPlay: { gameToPlay = $0 })
                    .accessibilityIdentifier("store-screen")
            }
            Tab(ControllerText.title, systemImage: "gamecontroller.fill", value: AppTab.controller) {
                ControllerPanelView()
            }
            Tab(L10n.text("settings"), systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
                    .accessibilityIdentifier("settings-screen")
            }
        }
        .environment(viewModel)
        .task {
            guard loadsRemoteData else { return }
            HandoffService.shared.start()
            await viewModel.load(authManager: authManager)
            viewModel.restoreResumableSession(
                from: cloudSessionCoordinator.serverSession
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                viewModel.cancelStoreConnection()
            }
            guard phase == .active, loadsRemoteData else { return }
            viewModel.startForegroundLibraryRefresh(authManager: authManager)
        }
        .onDisappear {
            viewModel.cancelForegroundLibraryRefresh()
        }
        .onChange(of: HandoffService.shared.incoming?.sessionId) { _, sessionId in
            guard sessionId != nil, let message = HandoffService.shared.incoming else { return }
            HandoffService.shared.incoming = nil
            Task { await receiveHandoff(message) }
        }
        .overlay(alignment: .top) {
            if let handoffStatus {
                Label(handoffStatus, systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("handoff-status")
            }
        }
        .animation(.easeInOut(duration: 0.25), value: handoffStatus)
        .sheet(isPresented: Bindable(HandoffService.shared).showsPairingHint) {
            VStack(alignment: .leading, spacing: 18) {
                Text(ControllerText.pairingSection)
                    .font(.title2.weight(.bold))
                Text(ControllerText.pairingSteps)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ControllerText.done) { HandoffService.shared.showsPairingHint = false }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("controller.pairing-hint.done")
            }
            .padding(32)
            .accessibilityIdentifier("controller.pairing-hint")
        }
        .overlay {
            if let relay = HandoffService.shared.relay {
                HandoffRelayView(
                    relay: relay,
                    onResumeHere: {
                        Task {
                            if let message = await HandoffService.shared.takeBackRelayedGame() {
                                await receiveHandoff(message)
                            }
                        }
                    },
                    onStop: { HandoffService.shared.stopRelay() }
                )
                .transition(.opacity)
            }
        }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                MemoryLifecycleCoordinator.shared.streamDidClose()
                directSessionToResume = nil
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            } else {
                MemoryLifecycleCoordinator.shared.streamWillOpen()
            }
        }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(
                game: game,
                settings: viewModel.streamSettings,
                existingSession: sessionToResume,
                directSession: directSessionToResume,
                onDismiss: {
                    gameToPlay = nil
                    sessionToResume = nil
                },
                onLeave: { leftGame, session in
                    viewModel.resumableSession = ResumableSession(
                        game: leftGame,
                        session: session,
                        leftAt: Date()
                    )
                }
            )
            .environment(authManager)
            .environment(viewModel)
            .blocksGlobalControllerNavigation(mode: .streaming)
            .environment(controllerNavigation)
        }
    }
}

extension MainTabView {
    /// Picks up a session another Cloud TV device just let go of. The session
    /// keeps running at NVIDIA; this device claims it like any session started
    /// elsewhere on the same account.
    private func receiveHandoff(_ message: HandoffMessage) async {
        guard loadsRemoteData else { return }
        // Taking the game back from the TV ends this iPad's controller relay.
        HandoffService.shared.stopRelay()
        guard gameToPlay == nil else { return }
        handoffStatus = HandoffText.receiving(message.game.title)
        defer { handoffStatus = nil }

        // Look the session up in NVIDIA's own list right away, then retry
        // briefly while the sender lets go. Never use an address from the peer.
        var listed: ActiveSessionInfo?
        for attempt in 0 ..< 12 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(750))
            }
            await viewModel.refreshActiveSessions(authManager: authManager)
            listed = message.matchingSession(in: viewModel.activeSessions)
            if listed != nil {
                break
            }
        }
        guard let session = listed else {
            handoffStatus = HandoffText.notFound
            try? await Task.sleep(for: .seconds(5))
            return
        }
        guard gameToPlay == nil else { return }
        // Prefer this device's own catalog entry over the peer's copy.
        let localGame = (viewModel.libraryGames + viewModel.mainGames)
            .first { $0.id == message.game.id }
        directSessionToResume = nil
        sessionToResume = session
        HandoffService.shared.resumingFromHandoff = true
        gameToPlay = localGame ?? message.game
    }
}

extension GamesViewModel: CloudGamingProviderModeLifecycle {
    func deactivateForInactiveProvider() async {
        // Provider switching only suspends GFN work. The coordinator still owns
        // any parked server lease, so keep the metadata required to resume it
        // when this mode is recreated. Logout and Reset retain their own clears.
        prepareForLogout()
    }
}

private nonisolated enum AppTab: CloudNowTabSelection {
    case home
    case library
    case store
    case controller
    case settings

    static let first = AppTab.home
    static let last = AppTab.settings

    var next: AppTab {
        switch self {
        case .home:
            .library
        case .library:
            .store
        case .store:
            .controller
        case .controller:
            .settings
        case .settings:
            .home
        }
    }

    var previous: AppTab {
        switch self {
        case .home:
            .settings
        case .library:
            .home
        case .store:
            .library
        case .controller:
            .store
        case .settings:
            .controller
        }
    }
}
