# Tester les fonctionnalités communautaires & de vol

Protocole pratique pour valider le boucle communautaire de bout en bout,
sans attendre un vrai vol.

## Matériel

- iPhone principal (compte A — ton compte, `contact@xavierkain.fr`)
- Un 2e appareil OU le simulateur Xcode (compte B — ex. `xk.tarifa@gmail.com`)
- La console Appwrite (projet `69524ce30037813a6abb`, région fra)

APNs ne fonctionne PAS dans le simulateur : tout ce qui est push se teste sur
appareil réel. Tout le reste (reports, feed, follows, kudos, leaderboard,
Explore) marche aussi dans le simulateur.

## 1. Vols sans voler — le simulateur de vol intégré

Settings › Developer mode ON, puis :

- **Simulate a Flight (Live)** : vol iPhone complet (GPS, alti, vario) qui se
  sauvegarde comme un vrai vol → déclenche le partage communautaire, la
  présence "flying now", le snapshot météo au décollage.
- **Simulate flight on Watch** : même chose côté Watch (teste l'outbox + ACK).
- **Generate Test Flights** : 20 vols historiques d'un coup (stats, spots,
  backfill météo).

## 2. Boucle communautaire à deux comptes

1. Compte A (iPhone) : Settings › Community → Share my flights ON, présence ON,
   suivre un spot (cloche sur la page du spot).
2. Compte B (2e appareil/simulateur) : se connecter, poster un report de
   conditions sur ce même spot.
3. Attendus côté A :
   - push "conditions" reçue (< 30 s, via la fonction `notify-fanout`),
   - le report apparaît dans "Conditions now" (tirer pour rafraîchir ou
     rouvrir la page — cache 5 min),
   - le tap sur la push ouvre le spot (deep link).
4. Compte B : simuler un vol sur le spot → côté A : "🪂 1 flying now" sur la
   page spot et dans Explore, vol partagé cliquable dans Community.
5. Follows : profil public de B (via leaderboard ou feed) → Follow → le vol
   de B apparaît dans le Community Feed de A ; kudos ↔ visibles des deux côtés.

## 3. Vérification côté serveur (console Appwrite)

- `spot_reports` : 1 ligne par report (TTL 3 h).
- `shared_flights` : 1 ligne par vol partagé (ID = UUID du vol → re-partage
  idempotent, jamais de doublon).
- `presence` : 1 ligne par pilote en vol (TTL 2 h).
- Functions › notify-fanout › Executions : logs du fan-out
  ("Fan-out for <spotKey>: N users…").

## 4. Push

- Test direct : Console → Messaging → Create push message → cibler ton user.
- Test bout-en-bout : report depuis le compte B sur un spot suivi par A.
- Cibles : Console → Auth → user → Targets (une target `push` doit exister).

## 5. Ce qui doit "fail soft" (à vérifier de temps en temps)

Mode avion → l'app doit rester 100 % fonctionnelle : les sections
communautaires se cachent ou gardent leur dernier état, jamais d'erreur
bloquante, les vols se sauvegardent normalement.
