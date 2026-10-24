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

    static var notFound: String {
        isFrench
            ? "Session introuvable. Les deux appareils doivent être connectés au même compte GeForce NOW."
            : "Session not found. Both devices must be signed in to the same GeForce NOW account."
    }

    static var relayTitle: String {
        isFrench ? "Tu joues sur l’Apple TV" : "Playing on Apple TV"
    }

    static func relayDetail(controller: String) -> String {
        isFrench
            ? "\(controller) reste connectée à l’iPad et pilote l’Apple TV. Garde Cloud TV ouvert ici."
            : "\(controller) stays paired to this iPad and drives the Apple TV. Keep Cloud TV open here."
    }

    static var relayMenuHint: String {
        isFrench
            ? "Bouton Home de la manette : menu pause sur la TV"
            : "Controller Home button: pause menu on the TV"
    }

    static var resumeHere: String {
        isFrench ? "Reprendre sur l’iPad" : "Continue on iPad"
    }

    static var stopRelay: String {
        isFrench ? "Arrêter le relais de la manette" : "Stop relaying the controller"
    }
}
