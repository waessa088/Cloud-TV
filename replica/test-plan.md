# Plan de test — Cloud TV

Portée : GeForce NOW sur Apple TV et iPad, et la bascule d'un appareil à l'autre.
La partie streaming vient de CloudNow et garde sa propre suite de tests (tvOS, CI « Tests »).

Légende : ✅ automatisé (CI) · 🖐 à vérifier à la main sur tes appareils · ⏳ en attente

## F01 — Envoyer la partie de l'iPad vers l'Apple TV (et retour)

| cas | description | comment |
| --- | --- | --- |
| F01-H1 | le message de bascule se code et se décode à l'identique (accents, emoji) | ✅ `HandoffTests.roundTrip` |
| F01-H2 | l'appareil qui reçoit reprend uniquement la session listée par NVIDIA, avec l'adresse fournie par NVIDIA | ✅ `resolvesAgainstServerList` |
| F01-H3 | chaque version s'annonce avec le bon type d'appareil | ✅ `deviceKind` |
| F01-H4 | les libellés nomment l'appareil cible | ✅ `labels` |
| F01-H5 | iPad en jeu → menu pause → « Envoyer sur l'Apple TV » → la TV reprend la partie en quelques secondes, l'iPad revient à l'accueil | 🖐 |
| F01-H6 | même chose dans l'autre sens (TV → « Reprendre sur l'iPad ») | 🖐 |
| F01-E1 | message trop gros refusé avant décodage | ✅ `rejectsOversizedPayloads` |
| F01-E2 | l'appareil qui envoie oublie sa session au lieu de la « garer » (sinon elle serait coupée à l'expiration) | ✅ `releasedLeaseIsForgottenNotParked` |
| F01-E3 | la TV est éteinte ou Cloud TV fermé dessus → message d'erreur, la partie continue sur l'iPad | 🖐 |
| F01-E4 | Wi-Fi différent / appareil absent → aucun bouton de bascule affiché | 🖐 |
| F01-E5 | double appui sur le bouton → un seul envoi (bouton désactivé pendant l'envoi) | 🖐 |
| F01-E6 | la TV joue déjà à autre chose → la demande est ignorée, la partie en cours n'est pas coupée | 🖐 |
| F01-N1 | contenu illisible, vide ou tronqué refusé | ✅ `rejectsMalformedPayloads` |
| F01-N2 | identifiant de session vide ou démesuré refusé | ✅ `rejectsBadSessionIdentifiers` |
| F01-N3 | autre version du protocole refusée | ✅ `rejectsOtherVersions` |
| F01-N4 | session absente de la liste NVIDIA, ou sans adresse → jamais reprise | ✅ `refusesUnlistedSessions` |
| F01-N5 | aucune adresse de serveur ne transite sur le réseau local | ✅ `noServerAddressOnTheWire` |
| F01-N6 | les deux appareils sur des comptes NVIDIA différents → « Session introuvable » | 🖐 |

## F02 — Jouer sur iPad

| cas | description | comment |
| --- | --- | --- |
| F02-H1 | l'app compile pour iPadOS et produit une IPA | ✅ CI « Build iPadOS » |
| F02-H2 | connexion NVIDIA, accueil, bibliothèque, lancement d'un jeu | 🖐 |
| F02-H3 | manette Bluetooth / USB-C reconnue en jeu, vibrations | 🖐 |
| F02-H4 | clavier et souris en jeu | 🖐 |
| F02-H5 | bouton pause (coin haut gauche) ouvre le menu | 🖐 |
| F02-E1 | carrousel : balayer gauche/droite change de jeu, vers le haut ouvre la fiche | 🖐 |
| F02-E2 | rotation : l'app reste en paysage | 🖐 |
| F02-E3 | première ouverture : iPadOS demande l'accès au réseau local → accepter | 🖐 |

## F03 — Jouer sur Apple TV

| cas | description | comment |
| --- | --- | --- |
| F03-H1 | suite de tests CloudNow d'origine (tvOS) | ⏳ CI « Tests » |
| F03-H2 | lancement d'un jeu en 4K HDR (selon abonnement) | 🖐 |

## F04 — Garder la manette (relais iPad → Apple TV)

| cas | description | comment |
| --- | --- | --- |
| F04-H1 | un paquet de manette se code et se décode à l'identique | ✅ `packetRoundTrip` |
| F04-H2 | la TV n'accepte que le jeton convenu lors de la bascule | ✅ `inboxAcceptsTokenHolder` |
| F04-H3 | le message de bascule transporte le jeton et la demande de libération | ✅ `handoffMessageRelayFields` |
| F04-H4 | après « Envoyer sur l'Apple TV », la manette de l'iPad pilote le jeu sur la TV sans réappairage | 🖐 |
| F04-H5 | bouton Home de la manette → menu pause sur la TV | 🖐 |
| F04-H6 | « Reprendre sur l'iPad » depuis l'écran de relais : la TV lâche la partie, l'iPad la reprend | 🖐 |
| F04-N1 | paquet tronqué ou mauvais en-tête refusé | ✅ `rejectsMalformedPackets` |
| F04-N2 | autre jeton, ou aucune session → ignoré | ✅ `inboxRejectsStrangers` |
| F04-E1 | paquets en désordre ou dupliqués ignorés | ✅ `inboxDropsOldSequences` |
| F04-E2 | relais coupé (iPad en veille) → manette neutre, aucun bouton bloqué | ✅ `inboxGoesStale` |
| F04-E3 | fin de session → plus rien n'est accepté | ✅ `inboxEndSession` |
