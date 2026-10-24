import SwiftUI

/// Wrappers for SwiftUI modifiers that only exist on tvOS.
///
/// The app target builds for both tvOS and iPadOS. On tvOS these forward to the
/// native focus-engine and Siri Remote modifiers; on iPadOS they are no-ops,
/// because touch, pointer, and the iPad back gesture replace them.
extension View {
    /// Siri Remote Menu / controller B. iPadOS has no equivalent hardware button.
    @ViewBuilder
    func tvExitCommand(perform action: (() -> Void)?) -> some View {
        #if os(tvOS)
            onExitCommand(perform: action)
        #else
            self
        #endif
    }

    /// Siri Remote Play/Pause.
    @ViewBuilder
    func tvPlayPauseCommand(perform action: (() -> Void)?) -> some View {
        #if os(tvOS)
            onPlayPauseCommand(perform: action)
        #else
            self
        #endif
    }

    /// Groups focusable children for the tvOS focus engine.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
            focusSection()
        #else
            self
        #endif
    }

    /// tvOS lift-and-parallax card button style; a plain style on iPadOS.
    @ViewBuilder
    func tvCardButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(.card)
        #else
            buttonStyle(.plain)
        #endif
    }

    /// iPadOS: hides the status bar and the Home indicator (no-op on tvOS).
    @ViewBuilder
    func immersiveOnIPad() -> some View {
        #if os(iOS)
            statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        #else
            self
        #endif
    }
}
