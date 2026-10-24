# Recon map : CloudGear – Navigateur Gaming (iOS / iPadOS + version Mac)

Scope : le cœur du produit — un navigateur dédié au cloud gaming qui ouvre les services (GeForce NOW, Xbox Cloud Gaming, Amazon Luna, Boosteroid, jeux HTML5) en plein écran avec manette, souris/clavier et lancement rapide. Cibles : iPhone, iPad et **Mac natif** (macOS). L'app Apple TV, les lunettes AR et visionOS sont hors v1.
For : à confirmer (produit à vendre sur l'App Store / Mac App Store ?)
Date : 2026-10-24

## Sources

| # | source | URL | notes |
| --- | --- | --- | --- |
| 1 | Fiche App Store (FR) | https://apps.apple.com/fr/app/cloudgear-navigateur-gaming/id6751054342 | description complète, IAP, historique des versions 1.0 → 2.1, 4 avis |
| 2 | Fiche App Store (US) | https://apps.apple.com/us/app/-/id6751054342 | même app, prix en dollars |
| 3 | 9to5Mac, Indie App Spotlight (22/08/2026) | https://9to5mac.com/?p=1065627 | handoff Apple TV, widgets, prix US |
| 4 | AlternativeTo | https://alternativeto.net/software/cloudgear/about | liste iPhone/iPad seulement |
| 5 | Politique de confidentialité | https://cloudgear.app/privacy/ | à lire avant le build |
| 6 | Le compte de l'utilisateur | — | pas encore utilisé ; captures à ranger dans `replica/screens/` |

Aucune doc d'aide publique ni changelog séparé trouvés : l'historique des versions de la fiche App Store en tient lieu. Les captures de la fiche ne sont pas lisibles en texte, donc l'inventaire d'écrans ci-dessous est **déduit des fonctionnalités** (confiance moyenne) et doit être confirmé avec des captures.

## Mac : ce que fait l'original aujourd'hui

La fiche ne liste pas macOS, mais un avis l'utilise sur MacBook Pro M1 en 4K/120 Hz : c'est l'app iPad qui tourne sur Mac Apple Silicon. **Une vraie app Mac native (fenêtre, menus, raccourcis, plein écran macOS, Intel exclu) est donc un angle de différenciation**, pas juste une copie.

## Core loop

Ouvrir son service de cloud gaming dans un navigateur sans barre ni limites de Safari, en plein écran, et jouer à la manette ou au clavier-souris avec la meilleure image possible — en un tap depuis un favori.

## Screens

| ID | screen | route / how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S01 | Accueil / lanceur | ouverture de l'app | choisir un service ou un favori | grille de services, grille de favoris, bouton Réglages | vide (aucun favori), rempli |
| S02 | Paywall / essai | 1er lancement, ou fonction verrouillée | vendre l'abonnement | 3 offres (mois, an, à vie), essai 7 j, Restaurer | défaut, achat en cours, erreur, déjà abonné |
| S03 | Navigateur / session de jeu | tap sur un service ou un favori | le jeu, en plein écran | WebView plein écran, barre auto-masquée, bouton Accueil | chargement, en jeu, erreur réseau, page de connexion du service |
| S04 | Overlay performances | raccourci / réglage | afficher fps, débit, latence, pertes de paquets | HUD semi-transparent | masqué, affiché |
| S05 | Menu en jeu | bouton Xbox / geste / raccourci | actions rapides sans quitter | volume global, souris virtuelle, écran noir, recharger, quitter | ouvert, fermé |
| S06 | Souris virtuelle (iOS) | menu en jeu | pointer au doigt | curseur, zone tactile | actif, inactif |
| S07 | Réglages | S01 → Réglages | tous les paramètres | sections, toggles, sliders, pickers | défaut |
| S08 | Réglages vidéo | S07 | résolution, fps, codec, HDR, taille/position image, moteur alternatif | pickers, toggles | selon service |
| S09 | Réglages manette | S07 | rumble, anti-deadzone, mapping Steam Controller | listes, sliders, éditeur de mapping | manette connectée / absente |
| S10 | Réglages par service | S07 | options propres à chaque service (ex. scripts Better xCloud) | liste de services | — |
| S11 | Éditeur de favori | appui long sur un jeu / S01 | nommer, icône, URL, ordre | champs, image | création, édition |
| S12 | Confidentialité / données | S07 | vider cookies et cache, se déconnecter des services | boutons destructifs + confirmation | confirmation |
| S13 | Widgets écran d'accueil | système iOS | lancer un favori sans ouvrir l'app | widget 1 jeu, widget grille 4 favoris | vide, rempli |
| S14 | Sortie écran externe | câble branché | afficher le jeu sur la TV, l'iPhone sert d'écran noir/manette | vue externe, écran noir | branché, débranché |
| S15 | (Mac) Fenêtre principale | lancement macOS | même chose que S01/S03 en fenêtre | barre latérale services/favoris, barre d'outils | fenêtré, plein écran |
| S16 | (Mac) Préférences | ⌘, | réglages façon macOS | onglets | — |

## Flows

```
F01 Première ouverture → essai gratuit
    S01 → S02 → (achat StoreKit) → S01
    happy path clicks : 3
    edge : achat annulé, déjà abonné sur un autre appareil (Restaurer), pas de réseau

F02 Jouer à GeForce NOW (cœur)
    S01 → S03 (page du service) → connexion au compte du joueur → lancer un jeu → plein écran
    happy path clicks : 2 dans l'app (+ ceux du service)
    edge : le service refuse le navigateur (user agent), session expirée, Wi-Fi instable, manette déconnectée en jeu

F03 Créer un favori et le lancer en un tap
    S03 (jeu ouvert) → ajouter aux favoris → S11 → S01 ; puis tap sur le favori → S03 directement dans le jeu
    happy path clicks : 3 pour créer, 1 pour lancer
    edge : URL qui expire, favori sur un autre appareil (iCloud), service différent

F04 Lancer depuis un widget ou Spotlight
    S13 → S03
    happy path clicks : 1
    edge : abonnement expiré (→ S02), favori supprimé

F05 Jouer au clavier-souris
    S03 → souris branchée → mode bureau auto + pointer lock
    happy path clicks : 0
    edge : sortie du pointer lock, touches système interceptées (⌘, Échap)

F06 Jouer sur la TV (écran externe)
    S03 → câble branché → S14, iPhone en écran noir
    happy path clicks : 1
    edge : débranchement en jeu, résolution native de l'écran, HDR non supporté

F07 Régler la qualité
    S03 → S05 ou S07 → S08 → retour au jeu
    happy path clicks : 3
    edge : réglage non supporté par le service, rechargement nécessaire

F08 (Mac) Jouer en fenêtre puis plein écran
    S15 → service → ⌃⌘F
    happy path clicks : 2
    edge : plusieurs écrans, ProMotion 120 Hz, manette Bluetooth
```

## Components

| component | variants | states | used on |
| --- | --- | --- | --- |
| Tuile de service | grande, compacte | défaut, pressé, verrouillé | S01, S15 |
| Tuile de favori | avec image, avec icône | défaut, pressé, édition, glisser | S01, S13, S15 |
| Carte d'offre | mois, an, à vie (mise en avant) | défaut, sélectionnée, achat en cours | S02 |
| WebView de jeu | plein écran, fenêtré (Mac) | chargement, en jeu, erreur | S03, S15 |
| HUD performances | compact, détaillé | masqué, visible | S04 |
| Menu en jeu | — | ouvert, fermé | S05 |
| Ligne de réglage | toggle, slider, picker, bouton | défaut, désactivé (non supporté) | S07–S12, S16 |
| Éditeur de mapping | manette → clavier/souris | vide, rempli, conflit | S09 |
| Curseur virtuel | styles de curseur | actif, inactif | S06 |
| Dialogue de confirmation | destructif | — | S12 |
| Widget | 1 jeu, grille 2×2 | vide, rempli, verrouillé | S13 |

## Inferred data model

Pas de backend visible : tout semble local + iCloud. Les comptes des services restent dans les cookies de la WebView.

```
Service      id, nom, url_de_base, user_agent, options (résolution max, fps max, codecs, scripts)
             evidence : description « Supported Services », réglages par service (v2.1)
             confidence : high (liste figée côté app)

Favorite     id, titre, url, service_id, image, ordre, créé_le
             evidence : Quick Launch (v1.6), personnalisation des favoris, widgets, Spotlight
             confidence : high ; synchro iCloud (CloudKit ou NSUbiquitousKeyValueStore) : medium

Settings     vidéo (résolution, fps, codec, hdr, taille, position, moteur_alternatif),
             audio (volume_global, canaux), entrée (rumble, anti_deadzone, desktop_auto, curseur),
             affichage (overlay_perf, écran_noir_externe)
             evidence : historique 1.4 → 2.1
             confidence : high pour l'existence, guess pour le stockage (UserDefaults par appareil ?)

ControllerMapping  id, manette (type), bouton → touche/clic, sensibilité_trackpad
             evidence : mapping Steam Controller (v2.1)
             confidence : medium

Entitlement  produit (mensuel | annuel | à_vie), expire_le, essai
             evidence : IAP de la fiche, « subscriptions sync across devices » (v1.3)
             confidence : high (StoreKit 2, pas de compte maison)
```

Relations : Service 1-n Favorite, Service 1-n options ; Settings unique par appareil ; Entitlement porté par l'Apple ID.

## Feature matrix

Voir `features.csv`. Must : 11, should : 12, could : 6, skip : 6.

## Out of scope (cannot or should not be cloned)

- **Les jeux et les services eux-mêmes** : le clone ouvre GeForce NOW, Xbox Cloud Gaming, etc. ; il ne les héberge pas et ne peut rien promettre sur leur qualité. Les joueurs utilisent leurs propres comptes.
- **Logos et marques des services** dans l'interface et la fiche : il faut des tuiles avec texte simple ou icônes neutres, et la même mention « non affilié » que l'original. À valider avec chaque marque avant d'utiliser un nom dans le titre de la fiche.
- **L'app Apple TV** : tvOS n'a pas de WebKit public ; l'original passe par un mécanisme de transfert qu'on ne voit pas de l'extérieur. Hors v1, à rechercher à part.
- **Lunettes AR, visionOS** : surtout du test matériel ; un écran externe générique couvre la plupart des lunettes USB-C.
- **Better xCloud** : script tiers ; ne l'intégrer qu'après lecture de sa licence, sinon laisser l'utilisateur le charger lui-même.
- **Le nom, l'icône, les textes et les captures de CloudGear.**

## Risques à garder en tête

- **Conditions des services** : les services filtrent parfois les navigateurs ; changer le user agent pour passer peut aller contre leurs conditions. À vérifier service par service.
- **App Review** : un « navigateur de jeux » qui n'est qu'une WebView peut être refusé (règles 4.2 fonctionnalité minimale, 4.3 spam/copie). La valeur ajoutée (manettes, overlay, favoris, Mac natif) doit être visible.
- **Moteur WebKit imposé sur iOS** : la qualité d'image, les codecs (AV1, H.265) et l'API Gamepad dépendent de WKWebView ; on règle ce qu'Apple expose, pas plus.

## Size

Écrans 16, flows 8, entités 5.
Parties difficiles : (1) entrées dans WKWebView — Gamepad API, vibrations, pointer lock, souris virtuelle, mapping Steam Controller ; (2) image et latence — plein écran réel, frame pacing, HDR, 120 Hz, écran externe ; (3) compatibilité de chaque service (user agent, scripts) qui casse à chaque mise à jour côté service.
Taille : **M** (quelques semaines) pour iPhone/iPad + Mac en SwiftUI multiplateforme sur le cœur ; **L** si on ajoute Steam Controller, Apple TV et AR.
