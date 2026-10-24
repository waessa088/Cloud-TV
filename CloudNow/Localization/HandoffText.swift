import Foundation

/// Strings for the iPad ↔ Apple TV handoff. Kept out of the shared L10n tables
/// so the upstream locale-parity checks stay untouched; French and English only.
enum HandoffText {
    private static var isFrench: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("fr")
    }

    static func sendTo(_ kind: HandoffDeviceKind) -> String {
        switch kind {
        case .appleTV:
            isFrench ? "Envoyer sur l’Apple TV" : "Send to Apple TV"
        case .iPad:
            isFrench ? "Reprendre sur l’iPad" : "Continue on iPad"
        }
    }

    static var sending: String {
        isFrench ? "Envoi en cours…" : "Sending…"
    }

    static var failed: String {
        isFrench
            ? "Appareil injoignable. Vérifiez qu’il est allumé, sur le même Wi-Fi, et que Cloud TV y est ouvert."
            : "Device unreachable. Check that it is on, on the same Wi-Fi, and has Cloud TV open."
    }

    static func receiving(_ title: String) -> String {
        isFrench ? "Reprise de \(title)…" : "Picking up \(title)…"
    }
}
