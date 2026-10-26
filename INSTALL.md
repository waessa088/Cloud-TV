# Installer Nimbus

Trois fichiers, un par appareil :
- `CloudTV-tvOS.ipa` → l'Apple TV (Apple TV 4K 2e génération ou plus récente, tvOS 26.2 ou plus), avec Sideloadly ;
- `CloudTV-iPadOS.ipa` → l'iPad (iPadOS 26 ou plus), avec Sideloadly ;
- `Nimbus-macOS.zip` → le Mac (macOS 26 ou plus), sans Sideloadly (voir « Installer sur le Mac »).

## 1. Télécharger les IPA

1. Ouvre https://github.com/waessa088/Cloud-TV/releases
2. Dans la version la plus récente (en haut), section « Assets », télécharge `CloudTV-tvOS.ipa`, `CloudTV-iPadOS.ipa` et `Nimbus-macOS.zip`.

## 2. Préparer Sideloadly sur le Mac

1. Installe Sideloadly depuis https://sideloadly.io (version macOS).
2. Ouvre-le et connecte-toi avec ton Apple ID (un compte gratuit suffit ; voir « Durée de validité » plus bas).

## 3. Installer sur l'iPad

1. Branche l'iPad au Mac en USB-C et déverrouille-le. Si l'iPad demande « Faire confiance à cet ordinateur ? », accepte.
2. Dans Sideloadly, choisis l'iPad dans la liste des appareils.
3. Glisse `CloudTV-iPadOS.ipa` dans la fenêtre, puis clique sur **Start**.
4. Sur l'iPad : **Réglages → Général → VPN et gestion de l'appareil**, touche ton Apple ID puis **Faire confiance**.
5. iPadOS demande aussi d'activer le **Mode développeur** (Réglages → Confidentialité et sécurité → Mode développeur) : active-le, l'iPad redémarre, confirme.

## 4. Installer sur l'Apple TV

1. Mac et Apple TV doivent être sur le même réseau.
2. Sur l'Apple TV : **Réglages → Télécommandes et appareils → App Remote et appareils**, et reste sur cet écran.
3. Dans Sideloadly, l'Apple TV apparaît dans la liste des appareils ; choisis-la. Un code s'affiche sur la TV : tape-le dans Sideloadly pour les jumeler.
4. Glisse `CloudTV-tvOS.ipa` dans Sideloadly, puis clique sur **Start**.

## 5. Premier lancement

1. Sur chaque appareil, ouvre **Cloud TV** et connecte-toi au **même compte GeForce NOW**.
2. Sur l'iPad, accepte la demande d'accès au **réseau local** : c'est ce qui permet de trouver l'Apple TV.

## Utiliser la bascule

1. Lance un jeu sur l'iPad.
2. Ouvre le menu pause : bouton en haut à gauche de l'écran, ou bouton Menu de la manette.
3. Appuie sur **« Envoyer sur l'Apple TV »**. Cloud TV doit être ouvert sur la TV.
4. En quelques secondes, la TV reprend la partie là où tu en étais et l'iPad revient à l'accueil.
5. Pour revenir à l'iPad : menu pause sur la TV → **« Reprendre sur l'iPad »** (Cloud TV ouvert sur l'iPad).

La manette Bluetooth ne suit pas toute seule : une manette PS5 ou Xbox n'est appairée qu'à un appareil à la fois. Le plus simple est d'avoir une manette par appareil, ou une manette multi-profils.

## Durée de validité

- **Apple ID gratuit** : les apps expirent au bout de **7 jours**. Active l'**actualisation automatique** dans Sideloadly : il les re-signe tout seul tant que le Mac est allumé et sur le même réseau. Limite Apple : 3 apps installées de cette façon par appareil.
- **Compte développeur payant (99 $/an)** : les apps restent valides **un an**, sans rien faire.

## Installer sur le Mac

1. Double-clique sur `Nimbus-macOS.zip` : il se décompresse en **Nimbus.app**. Glisse-la dans **Applications**.
2. Au premier lancement, macOS refuse d'ouvrir une app qui ne vient pas de l'App Store. Va dans **Réglages Système › Confidentialité et sécurité**, descends jusqu'à « Nimbus a été bloquée » et clique sur **Ouvrir quand même**, puis confirme.
3. Accepte l'accès au **réseau local** : c'est ce qui permet de voir l'iPad et l'Apple TV.

Sur Mac, la souris ou le trackpad est capturé par le jeu pendant la partie. **⌘⇧M** (ou le bouton PS de la manette) ouvre le menu et libère la souris.

L'app Mac n'expire pas : elle est signée localement (« ad hoc »), sans compte Apple.

## Manette : modes et latence

Onglet **Manette** (ou carte « Manette » du menu en jeu) :
- **Automatique (recommandé)** : manette locale quand tu joues ici ; après un passage sur l'Apple TV, l'iPad ou le Mac relaie sa manette, sauf si une manette est connectée directement à la TV (elle est alors prioritaire, sans double commande).
- **Bluetooth direct** : pas de relais. Il faut appairer la manette à l'appareil qui affiche le jeu (étapes affichées dans l'app). Aucune app ne peut déplacer un appairage Bluetooth automatiquement.
- **Relais Wi-Fi** et **USB** : la manette reste sur l'iPad ou le Mac et ses commandes partent vers l'Apple TV. Le mode USB ne fonctionne que si iPadOS reconnaît la manette par câble.

L'écran affiche la **latence ajoutée par le relais** (médiane, P95, P99), mesurée en continu. C'est une estimation (aller-retour ÷ 2) qui dépend du Wi-Fi, pas une garantie.

Si la manette ne répond plus en revenant sur l'iPad, c'est qu'elle est restée appairée à l'Apple TV : remets-la en appairage (Share + PS pendant 3 secondes) et choisis-la dans Réglages › Bluetooth.
