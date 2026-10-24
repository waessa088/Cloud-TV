# Bugs — Cloud TV

### BUG-001: un appareil du Wi-Fi pouvait détourner le jeton NVIDIA

- Severity: S1
- Flow / case: F01 / F01-N4, F01-N5
- Screen: accueil Apple TV ou iPad (réception d'une bascule)
- Build: a9f73ef (première version de la bascule)  Device: revue de code

Steps
1. Un appareil du réseau local envoie un message de bascule avec une adresse de serveur qu'il contrôle.
2. Cloud TV reprend la « session » en appelant `claimSession(serverIp:)`.

Expected: la requête, qui porte le jeton NVIDIA, ne part que vers un serveur NVIDIA.
Actual: elle partait vers l'adresse fournie dans le message.
Evidence: `CloudMatchClient.claimSession` construit `https://\(serverIp)` et y envoie le jeton ; trouvé par la revue `security-review`.
Suspected cause: le message transportait `serverIp` / `signalingUrl` et le receveur les utilisait.
Status: fixed — le message ne transporte plus d'adresse ; le receveur ne reprend qu'une session présente dans la liste `getActiveSessions` de NVIDIA, avec l'adresse de cette liste. Tests : `refusesUnlistedSessions`, `noServerAddressOnTheWire`, `resolvesAgainstServerList`.

### BUG-002: le style de code (lint) refusait deux constructions

- Severity: S4
- Flow / case: —
- Build: CI « Lint »

Actual: indentation d'un `#if` placé au milieu d'une chaîne de modificateurs (carrousel), ordre des mots-clés `private nonisolated final`.
Status: fixed (carrousel déplacé dans un modificateur dédié ; ordre `private final nonisolated`).

### BUG-003: image rognée sur iPad

- Severity: S2
- Flow / case: F02 / F02-H2
- Build: dde83e3  Device: iPad (photo de Wail, Project Zomboid)

Steps
1. Lancer un jeu sur iPad.

Expected: toute l'image du jeu est visible.
Actual: les côtés sont coupés (« roject », « MBOID »).
Suspected cause: `videoGravity = .resizeAspectFill`, prévu pour un écran 16:9 ; l'iPad n'est pas en 16:9.
Status: fixed — `.resizeAspect` sur iPad (bandes noires fines, rien de coupé).

### BUG-004: barre d'état et indicateur d'accueil visibles en jeu

- Severity: S3
- Flow / case: F02 / F02-H2
- Build: dde83e3  Device: iPad

Actual: l'heure, le Wi-Fi et la batterie s'affichent par-dessus le jeu ; le bouton pause chevauche l'heure.
Status: fixed — barre d'état et indicateur masqués pendant le jeu, bouton pause décalé et plus discret.

### BUG-005: deux pointeurs (souris décalée)

- Severity: S2
- Flow / case: F02 / F02-H4
- Build: dde83e3  Device: iPad + souris

Actual: le pointeur d'iPadOS et le curseur du jeu bougent séparément.
Suspected cause: la souris est envoyée au jeu en déplacements relatifs (GCMouse), mais le pointeur système restait affiché et libre.
Status: fixed — pointeur verrouillé et masqué pendant le jeu, rendu dans le menu pause.

### BUG-006: la manette devait être réappairée à chaque bascule

- Severity: S2
- Flow / case: F01 / F01-H5
Status: fixed — la manette reste appairée à l'iPad et ses commandes sont relayées à l'Apple TV par le Wi-Fi local (tests `RemoteGamepadRelayTests`).

## À vérifier (non reproduit)

- Si Cloud TV est en mode Xbox sur la TV au moment de la bascule, la demande n'est traitée qu'au retour en mode GeForce NOW.
- Les doigts sur l'écran de l'iPad ne contrôlent pas le jeu (seuls manette, clavier, souris) : comportement attendu, à confirmer en usage.
