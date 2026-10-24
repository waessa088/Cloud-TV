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

## À vérifier (non reproduit)

- Si Cloud TV est en mode Xbox sur la TV au moment de la bascule, la demande n'est traitée qu'au retour en mode GeForce NOW.
- Les doigts sur l'écran de l'iPad ne contrôlent pas le jeu (seuls manette, clavier, souris) : comportement attendu, à confirmer en usage.
