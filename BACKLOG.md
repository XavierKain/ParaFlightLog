# SoarX — Backlog produit

> Idées notées le 2026-06-12 (Xavier). À prioriser plus tard — aucune implémentation engagée.
> Étude détaillée : `docs/superpowers/specs/2026-06-12-soarx-etude-fonctionnalites.md`

## 1. Intégration SoarX Voice

Intégrer l'app SoarX Voice (projet séparé : `/Users/xavier/VSCode3/SoarXVoice`) dans SoarX.

## 2. Type de vol au démarrage

Pouvoir définir le type de vol qu'on va faire avant/au début du vol : **soaring, thermique, planée (glide), airsurfing**, etc.
- Le champ `Flight.flightType` existe déjà en base ; il faut l'exposer dans le flux de démarrage (onglet Vol sur iPhone + écran Start sur la Watch) et dans les stats/filtres.

## 3. Voiles : possédées vs utilisées (cœur historique de l'app)

La raison d'être de l'app : traquer le temps de vol **par aile** pour deux usages distincts :
- **Mes voiles (possédées)** : heures totales de la voile → maintenance (retrim, révision), valeur à la revente.
- **Voiles empruntées/testées (pas à moi)** : seules comptent les heures d'**expérience pilote** sur ce type/taille d'aile — pas de suivi maintenance.

À faire : flag « possédée » sur Wing + éventuellement heures initiales à l'achat (occasion), date d'achat/revente, seuils d'alerte maintenance ; stats d'expérience agrégées par type d'aile et par taille.

## 4. Vario intégré (téléphone + Watch)

Pour les vols thermiques : un vario activable/désactivable sur iPhone **et** Apple Watch (bips/haptique selon taux de montée/descente).

## 5. Analyse verticale des traces GPS

Voir sur nos traces : vitesse horizontale **et verticale** (ascension en thermique, à la corde/treuil, en soaring), hauteurs atteintes et vitesse de montée. Coloration de trace par Vz, graphe altitude/temps, stats de montée.

## 6. S'inspirer de Wingman (wingmanfly.app)

App iOS de référence pour le thermique : vario très réactif iPhone/Watch, « thermal viewer » (trace colorée par montée), détection auto décollage/atterrissage, instruments en vol. Analyser et reprendre le meilleur.

## 7. S'inspirer de Surfr App v4 (kite)

Grosse mise à jour 4.0 : communautaire, spots, matériel, statistiques, modèles d'abonnement. « Exactement ce que j'avais en tête pour SoarX » → analyse en profondeur et adaptation au parapente.

## 8. React Native ?

Étudier la réécriture de l'app en React Native pour couvrir iPhone **et Android** (amis sur Android). Aujourd'hui : Swift/SwiftUI, iOS uniquement.

## Rappels V10.1 (déjà au ROADMAP)

Export/import IGC · Live Activities iOS · icône SoarX · tests unitaires · migration contacts d'urgence.
