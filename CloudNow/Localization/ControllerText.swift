import Foundation

/// French / English copy for the controller screen.
enum ControllerText {
    private static var isFrench: Bool {
        (Locale.preferredLanguages.first ?? "").hasPrefix("fr")
    }

    private static func pick(_ french: String, _ english: String) -> String {
        isFrench ? french : english
    }

    static var title: String {
        pick("Manette", "Controller")
    }

    static var done: String {
        pick("Terminé", "Done")
    }

    static var modeSection: String {
        pick("Mode", "Mode")
    }

    static var deviceSection: String {
        pick("Appareil connecté", "Connected device")
    }

    static var stateSection: String {
        pick("État de la connexion", "Connection state")
    }

    static var latencySection: String {
        pick("Latence du relais", "Relay latency")
    }

    static var testSection: String {
        pick("Test des boutons et joysticks", "Button and stick test")
    }

    static var pairingSection: String {
        pick("Changer d’appareil en Bluetooth", "Moving the controller over Bluetooth")
    }

    static func title(_ mode: ControllerMode) -> String {
        switch mode {
        case .automatic: pick("Automatique (recommandé)", "Automatic (recommended)")
        case .bluetoothDirect: pick("Bluetooth direct", "Direct Bluetooth")
        case .wifiRelay: pick("Relais Wi-Fi", "Wi-Fi relay")
        case .usb: pick("USB", "USB")
        }
    }

    static func detail(_ mode: ControllerMode) -> String {
        switch mode {
        case .automatic:
            pick(
                "Manette locale sur l’iPad. Sur l’Apple TV, une manette connectée directement à la TV est prioritaire ; sinon l’iPad relaie la sienne.",
                "Local controller on iPad. On Apple TV, a controller connected to the TV wins; otherwise the iPad relays its own."
            )
        case .bluetoothDirect:
            pick(
                "Aucun relais. La manette doit être appairée à l’appareil qui affiche le jeu : une intervention est nécessaire à chaque changement d’appareil.",
                "No relay. The controller must be paired to the device showing the game, which takes a manual step on each switch."
            )
        case .wifiRelay:
            pick(
                "La manette reste sur l’iPad et ses commandes sont envoyées à l’Apple TV par le réseau local.",
                "The controller stays on the iPad and its input is sent to Apple TV over the local network."
            )
        case .usb:
            pick(
                "Manette branchée à l’iPad par câble, relayée comme en Wi-Fi. Fonctionne seulement si iPadOS reconnaît la manette en USB.",
                "Controller cabled to the iPad, relayed like Wi-Fi. Works only if iPadOS recognises the controller over USB."
            )
        }
    }

    static var transportNote: String {
        pick(
            "Liaison : Bluetooth ou USB. iPadOS et tvOS n’indiquent pas aux apps lequel des deux est utilisé.",
            "Link: Bluetooth or USB. iPadOS and tvOS do not tell apps which one is in use."
        )
    }

    static var noController: String {
        pick("Aucune manette connectée à cet appareil", "No controller connected to this device")
    }

    static func charging(_ percent: Int) -> String {
        pick("\(percent) % · en charge", "\(percent)% · charging")
    }

    static var localActive: String {
        pick("Manette locale active : les commandes vont directement au jeu.", "Local controller active: input goes straight to the game.")
    }

    static var relayWaiting: String {
        pick("Relais lancé, en attente de réponse de l’Apple TV…", "Relay started, waiting for Apple TV…")
    }

    static var relayActive: String {
        pick("Relais Wi-Fi actif : cette manette pilote le jeu sur l’Apple TV.", "Wi-Fi relay active: this controller drives the game on Apple TV.")
    }

    static var relaySuspended: String {
        pick(
            "Relais en veille : l’Apple TV utilise une manette connectée directement. Rien n’est envoyé en double.",
            "Relay on standby: Apple TV is using a directly connected controller. Nothing is sent twice."
        )
    }

    static var receivingRelay: String {
        pick("Commandes reçues de l’iPad par le relais Wi-Fi.", "Receiving input from the iPad over the Wi-Fi relay.")
    }

    static var needsPairing: String {
        pick(
            "Aucune manette ici. Si elle était connectée à l’autre appareil, elle doit être réappairée (voir ci-dessous).",
            "No controller here. If it was connected to the other device, it must be paired again (see below)."
        )
    }

    static var median: String {
        pick("Médiane", "Median")
    }

    static func latencyNote(samples: Int) -> String {
        pick(
            "Latence ajoutée estimée (aller-retour ÷ 2), sur \(samples) mesures. Dépend du Wi-Fi : ce n’est pas une garantie.",
            "Estimated added latency (round trip ÷ 2) over \(samples) samples. Depends on Wi-Fi; not a guarantee."
        )
    }

    static var pairingSteps: String {
        pick(
            """
            Ni iPadOS ni tvOS ne permettent à une app de déplacer l’appairage Bluetooth : ce changement se fait à la main.
            1. Sur la DualShock 4, maintiens Share + PS environ 3 secondes, jusqu’à ce que la barre lumineuse clignote.
            2. Apple TV : Réglages › Télécommandes et appareils › Bluetooth › DUALSHOCK 4.
               iPad : Réglages › Bluetooth › DUALSHOCK 4.
            En pratique, la DualShock 4 se reconnecte au dernier appareil auquel elle a été appairée : après l’avoir appairée à l’Apple TV, il faut refaire ces étapes pour revenir sur l’iPad.
            """,
            """
            Neither iPadOS nor tvOS lets an app move a Bluetooth pairing, so this step is manual.
            1. On the DualShock 4, hold Share + PS for about 3 seconds until the light bar flashes.
            2. Apple TV: Settings › Remotes and Devices › Bluetooth › DUALSHOCK 4.
               iPad: Settings › Bluetooth › DUALSHOCK 4.
            In practice the DualShock 4 reconnects to the last device it was paired with, so after pairing it to Apple TV, repeat these steps to come back to the iPad.
            """
        )
    }

    static var missingOnIPad: String {
        pick(
            "Aucune manette sur l’iPad. Si elle est appairée à l’Apple TV, remets-la en appairage (Share + PS) et choisis-la dans Réglages › Bluetooth.",
            "No controller on the iPad. If it is paired to Apple TV, put it in pairing mode (Share + PS) and pick it in Settings › Bluetooth."
        )
    }
}
