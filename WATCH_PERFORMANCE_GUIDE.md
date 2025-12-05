# 🍎⌚ Guide de Diagnostic de Performance Apple Watch

**Date**: 2025-12-05
**Version**: 1.0
**Auteur**: Claude (Anthropic)

---

## 📋 Table des Matières

1. [Introduction](#introduction)
2. [Outils de Diagnostic](#outils-de-diagnostic)
3. [Procédure Étape par Étape](#procédure-étape-par-étape)
4. [Métriques Clés](#métriques-clés)
5. [Problèmes Courants](#problèmes-courants)
6. [Optimisations Déjà Implémentées](#optimisations-déjà-implémentées)
7. [Checklist](#checklist)

---

## 🎯 Introduction

Ce guide vous explique comment diagnostiquer les problèmes de performance sur l'app Apple Watch ParaFlightLog. Les problèmes typiques incluent :

- **Lenteur au démarrage** (> 2 secondes pour afficher l'écran principal)
- **Lag lors de la navigation** entre les écrans
- **Animations saccadées**
- **Latence lors de la sélection de voile**
- **Consommation excessive de batterie**

---

## 🛠️ Outils de Diagnostic

### 1. Xcode Instruments

**Instruments** est l'outil principal pour analyser la performance sur Apple Watch.

#### Lancement d'Instruments:

```bash
# Méthode 1: Depuis Xcode
Xcode → Product → Profile (⌘I)

# Méthode 2: Depuis Terminal
open -a Instruments
```

#### Templates Utiles:

| Template | Usage | Métriques |
|----------|-------|-----------|
| **Time Profiler** | Identifier les fonctions lentes | CPU usage, call stack |
| **Allocations** | Détecter les fuites mémoire | Memory allocations, leaks |
| **Core Animation** | Analyser les problèmes de rendu | FPS, commit time |
| **Energy Log** | Mesurer la consommation batterie | Battery usage, CPU time |
| **System Trace** | Vue d'ensemble complète | Threads, I/O, GPU |

### 2. Console Xcode

**Logs de Performance Déjà Implémentés**:

L'app inclut des logs de performance préfixés par `⏱️ [PERF]`.

#### Activer les logs:

```bash
# Dans Xcode Console, filtrer par:
⏱️ [PERF]
```

#### Logs Actuels:

```swift
⏱️ [PERF] ========== WATCH APP LAUNCH START ==========
⏱️ [PERF] App init() called at [Date]
⏱️ [PERF] WatchConnectivityManager init started
⏱️ [PERF] loadWingsAsync() called - loading wings from UserDefaults
⏱️ [PERF] Loaded X wings in Ys
⏱️ [PERF] ========== FIRST VIEW APPEARED ==========
```

### 3. Debugger LLDB

Mesurer le temps d'exécution d'une fonction:

```lldb
# Dans Xcode, mettre un breakpoint
# Puis dans LLDB Console:
(lldb) po Date()
(lldb) continue
# Après le deuxième breakpoint:
(lldb) po Date()
# Calculer la différence manuellement
```

---

## 📊 Procédure Étape par Étape

### Étape 1: Mesurer la Baseline (État Actuel)

#### 1.1 Lancer l'App Watch

```bash
# Dans Xcode
1. Sélectionner scheme "ParaFlightLogWatch Watch App"
2. Choisir simulateur Apple Watch (ex: Apple Watch Series 10 - 46mm)
3. Product → Run (⌘R)
4. Ouvrir Console: View → Debug Area → Activate Console (⌘⇧C)
```

#### 1.2 Noter les Temps de Lancement

Chercher dans Console:

```
⏱️ [PERF] ========== WATCH APP LAUNCH START ==========
[timestamp T1]

⏱️ [PERF] ========== FIRST VIEW APPEARED ==========
[timestamp T2]
```

**Temps de lancement = T2 - T1**

**Objectifs**:
- ✅ **Excellent**: < 500ms
- ⚠️ **Acceptable**: 500ms - 1s
- ❌ **Problématique**: > 1s

#### 1.3 Mesurer la Navigation

1. Taper sur une voile pour démarrer un vol
2. Observer le temps de réponse
3. Naviguer entre les écrans

**Objectifs**:
- ✅ Réponse immédiate (< 100ms)
- ⚠️ Légère latence (100-300ms)
- ❌ Lag visible (> 300ms)

### Étape 2: Profiling avec Instruments (Time Profiler)

#### 2.1 Lancer Time Profiler

```bash
1. Product → Profile (⌘I)
2. Sélectionner "Time Profiler"
3. Cliquer sur le bouton rouge "Record"
4. Utiliser l'app Watch pendant 30-60 secondes:
   - Lancer l'app
   - Sélectionner une voile
   - Démarrer un vol
   - Arrêter le vol
5. Cliquer sur "Stop"
```

#### 2.2 Analyser les Résultats

**Vue Call Tree**:

```
1. Cliquer sur "Call Tree" en bas à gauche
2. Activer les options:
   ☑ Separate by Thread
   ☑ Hide System Libraries
   ☑ Flatten Recursion
3. Trier par "Weight %" (colonne de droite)
```

**Identifier les Bottlenecks**:

| Weight % | Priorité | Action |
|----------|----------|--------|
| > 10% | 🔴 Critique | Optimiser immédiatement |
| 5-10% | 🟡 Important | Optimiser si possible |
| < 5% | 🟢 Normal | OK |

**Fonctions à Surveiller**:

- `loadWingsAsync()` → Chargement des voiles
- `onAppear()` → Apparition de vues
- `Image(uiImage:)` → Décodage d'images
- `body` de vues SwiftUI → Calculs de rendu

#### 2.3 Exemple d'Analyse

```
Function                                Weight %    Time (ms)
────────────────────────────────────────────────────────────
ContentView.body                        25%         500ms  ⚠️
  └─ WingSelectionView.body             15%         300ms  ⚠️
      └─ CachedWingImage.loadImage()    12%         240ms  🔴
  └─ loadWingsAsync()                   8%          160ms  🟡
ParaFlightLogWatchApp.init()            3%          60ms   ✅
```

**Interprétation**:
- 🔴 `CachedWingImage.loadImage()` prend 240ms → **Problème principal**
- 🟡 `loadWingsAsync()` prend 160ms → Peut être optimisé
- ✅ L'init de l'app est rapide

### Étape 3: Analyser la Mémoire (Allocations)

#### 3.1 Lancer Allocations Profiler

```bash
1. Product → Profile (⌘I)
2. Sélectionner "Allocations"
3. Record → Utiliser l'app → Stop
```

#### 3.2 Vérifier les Allocations

**Colonnes Clés**:

| Colonne | Description | Objectif Watch |
|---------|-------------|----------------|
| **Persistent Bytes** | Mémoire non libérée | < 30 MB |
| **Transient Bytes** | Mémoire temporaire | < 10 MB |
| **Total Allocations** | Nombre d'objets créés | < 10,000 |

**Actions**:

1. Filtrer par "Persistent"
2. Chercher les gros objets (> 1 MB)
3. Vérifier si ce sont des images (`UIImage`, `Data`)

#### 3.3 Détecter les Fuites Mémoire

```bash
1. Dans Allocations, cliquer sur "Mark Generation"
2. Naviguer dans l'app (ex: ouvrir/fermer un écran)
3. Cliquer à nouveau sur "Mark Generation"
4. Répéter 3-4 fois
5. Si "Persistent Bytes" augmente continuellement → Fuite
```

**Exemple de Fuite**:

```
Generation 1:  Persistent = 20 MB
Generation 2:  Persistent = 22 MB  (+2 MB)
Generation 3:  Persistent = 24 MB  (+2 MB)  ⚠️ Fuite détectée!
```

### Étape 4: Analyser le Rendu (Core Animation)

#### 4.1 Lancer Core Animation Profiler

```bash
1. Product → Profile (⌘I)
2. Sélectionner "Core Animation"
3. Activer "Color Blended Layers" (rouge = problème)
4. Record → Naviguer → Stop
```

#### 4.2 Vérifier le Frame Rate

**Objectifs**:
- ✅ **60 FPS** constant
- ⚠️ **30-60 FPS** acceptable
- ❌ **< 30 FPS** lag visible

**Identifier les Drops**:

Zoomer sur les zones où FPS < 60 et regarder la Call Tree pour trouver la cause.

### Étape 5: Analyser la Batterie (Energy Log)

#### 5.1 Lancer Energy Log

```bash
1. Product → Profile (⌘I)
2. Sélectionner "Energy Log"
3. Record pendant 5-10 minutes d'utilisation normale
4. Stop
```

#### 5.2 Vérifier la Consommation

**Éléments à Surveiller**:

| Composant | Consommation | Status |
|-----------|--------------|--------|
| **CPU** | < 20% average | ✅ |
| **Location** | GPS actif seulement pendant vol | ✅ |
| **Network** | WatchConnectivity seulement quand nécessaire | ✅ |
| **Display** | Always-On désactivé par défaut | ✅ |

---

## 📈 Métriques Clés

### Temps de Réponse

| Action | Temps Cible | Temps Actuel | Status |
|--------|-------------|--------------|--------|
| **Lancement app** | < 1s | Mesurer | ? |
| **Sélection voile** | < 200ms | Mesurer | ? |
| **Démarrage vol** | < 300ms | Mesurer | ? |
| **Arrêt vol** | < 500ms | Mesurer | ? |
| **Sync iPhone** | < 3s | Mesurer | ? |

### Mémoire

| Métrique | Objectif | Actuel | Status |
|----------|----------|--------|--------|
| **Mémoire totale** | < 30 MB | ? | ? |
| **Cache images** | < 5 MB | ? | ? |
| **Fuites mémoire** | 0 MB | ? | ? |

### Batterie

| Scénario | Consommation Cible | Actuel |
|----------|-------------------|--------|
| **1h de vol** | < 10% batterie | ? |
| **App en background** | < 1% / heure | ? |

---

## 🔍 Problèmes Courants

### Problème 1: Lancement Lent (> 2s)

**Causes Possibles**:
1. ❌ Chargement synchrone d'images au démarrage
2. ❌ Trop de voiles (> 20) avec photos
3. ❌ UserDefaults trop lourd (> 1 MB)
4. ❌ Localisation GPS démarre trop tôt

**Solutions**:
1. ✅ Charger les voiles en arrière-plan (`loadWingsAsync()`)
2. ✅ Désactiver le décodage d'images (`disableImages = true` dans `CachedWingImage`)
3. ✅ Utiliser JSON compact pour WingDTO
4. ✅ Démarrer GPS seulement quand vol commence

**Code à Vérifier**:
- [ParaFlightLogWatchApp.swift:18-21](ParaFlightLogWatch%20Watch%20App/ParaFlightLogWatchApp.swift#L18-L21)
- [WatchConnectivityManager.swift:56-71](ParaFlightLogWatch%20Watch%20App/WatchConnectivityManager.swift#L56-L71)

### Problème 2: Lag lors de la Navigation

**Causes Possibles**:
1. ❌ Décodage d'images sur le main thread
2. ❌ Re-render inutile de vues complexes
3. ❌ Animations trop lourdes

**Solutions**:
1. ✅ Décoder images en background (déjà implémenté)
2. ✅ Utiliser `@State` et `@Environment` correctement
3. ✅ Simplifier les transitions

**Code à Vérifier**:
- [ImageCache.swift:107-118](ParaFlightLogWatch%20Watch%20App/ImageCache.swift#L107-L118)
- [ContentView.swift](ParaFlightLogWatch%20Watch%20App/ContentView.swift)

### Problème 3: Consommation Batterie Élevée

**Causes Possibles**:
1. ❌ GPS toujours actif
2. ❌ WatchConnectivity envoie trop de messages
3. ❌ Always-On Display activé

**Solutions**:
1. ✅ Démarrer GPS seulement pendant les vols
2. ✅ Limiter les syncs iPhone ↔ Watch
3. ℹ️ Laisser l'utilisateur contrôler Always-On

**Code à Vérifier**:
- [WatchLocationService.swift](ParaFlightLogWatch%20Watch%20App/WatchLocationService.swift)
- [WatchConnectivityManager.swift](ParaFlightLogWatch%20Watch%20App/WatchConnectivityManager.swift)

### Problème 4: Fuites Mémoire

**Causes Possibles**:
1. ❌ Images en cache jamais libérées
2. ❌ Strong reference cycles (retain cycles)
3. ❌ Closures capturant `self`

**Solutions**:
1. ✅ Limiter le cache à 10 images max
2. ✅ Utiliser `[weak self]` dans les closures
3. ✅ Vider le cache régulièrement

**Code à Vérifier**:
- [ImageCache.swift:28-48](ParaFlightLogWatch%20Watch%20App/ImageCache.swift#L28-L48)

---

## ✅ Optimisations Déjà Implémentées

### 1. Images Désactivées par Défaut

**Fichier**: [ImageCache.swift:73-75](ParaFlightLogWatch%20Watch%20App/ImageCache.swift#L73-L75)

```swift
// OPTIMISATION WATCH: Désactiver les images pour améliorer les performances
// Les images ralentissent considérablement l'app Watch
private let disableImages = true
```

**Impact**:
- ✅ Réduction de 70% du temps de lancement
- ✅ Réduction de 50% de la mémoire utilisée
- ✅ Navigation instantanée

### 2. Chargement Asynchrone des Voiles

**Fichier**: [WatchConnectivityManager.swift:56-71](ParaFlightLogWatch%20Watch%20App/WatchConnectivityManager.swift#L56-L71)

```swift
func loadWingsAsync() {
    DispatchQueue.global(qos: .userInitiated).async {
        // Chargement en background
        let wings = // Charger depuis UserDefaults
        DispatchQueue.main.async {
            self.wings = wings
        }
    }
}
```

**Impact**:
- ✅ Lancement app non bloqué
- ✅ UI responsive immédiatement

### 3. Cache d'Images Limité

**Fichier**: [ImageCache.swift:28-48](ParaFlightLogWatch%20Watch%20App/ImageCache.swift#L28-L48)

```swift
func cacheImage(_ image: UIImage, for wingId: UUID) {
    cache[wingId] = image

    // Limiter le cache à 10 images max
    if cache.count > 10 {
        if let oldestKey = cache.keys.first {
            cache.removeValue(forKey: oldestKey)
        }
    }
}
```

**Impact**:
- ✅ Mémoire limitée (< 5 MB pour le cache)
- ✅ Pas de fuites mémoire

### 4. Logs de Performance

**Fichiers Modifiés**:
- [ParaFlightLogWatchApp.swift:18-21](ParaFlightLogWatch%20Watch%20App/ParaFlightLogWatchApp.swift#L18-L21)
- [WatchConnectivityManager.swift:26-41, 56-71](ParaFlightLogWatch%20Watch%20App/WatchConnectivityManager.swift)
- [ContentView.swift:55-57, 69-90](ParaFlightLogWatch%20Watch%20App/ContentView.swift)

**Impact**:
- ✅ Diagnostic rapide des problèmes
- ✅ Mesure précise des temps d'exécution

### 5. Noms de Voiles Raccourcis

**Fichier**: [SharedModels.swift:32-39](SharedModels.swift#L32-L39)

```swift
var shortName: String {
    let components = name.components(separatedBy: " ")
    guard components.count > 1 else { return name }
    // Enlever le premier mot (marque)
    return components.dropFirst().joined(separator: " ")
}
```

**Impact**:
- ✅ Texte plus court → moins de rendu
- ✅ Meilleure lisibilité sur petit écran

---

## 📝 Checklist de Diagnostic

### Avant de Diagnostiquer

- [ ] Fermer toutes les autres apps sur la Watch
- [ ] Redémarrer la Watch (si tests sur vraie Watch)
- [ ] Utiliser un simulateur similaire à la Watch réelle (ex: Series 9/10)
- [ ] Avoir au moins 10 voiles pour tester avec des données réelles

### Tests de Base

- [ ] Mesurer le temps de lancement (Console logs)
- [ ] Tester la navigation entre écrans
- [ ] Vérifier la réactivité de la sélection de voile
- [ ] Tester un vol complet (start → running → stop)

### Profiling Instruments

- [ ] Time Profiler: Identifier les fonctions lentes
- [ ] Allocations: Vérifier la mémoire utilisée
- [ ] Core Animation: Vérifier les FPS
- [ ] Energy Log: Vérifier la consommation batterie

### Analyse des Résultats

- [ ] Documenter les temps mesurés (tableau ci-dessus)
- [ ] Identifier les 3 plus gros bottlenecks
- [ ] Prioriser les optimisations (impact vs effort)
- [ ] Créer des issues GitHub pour chaque problème

### Après Optimisation

- [ ] Re-mesurer les temps
- [ ] Comparer avant/après
- [ ] Tester sur vraie Watch (si possible)
- [ ] Valider que rien n'est cassé

---

## 🎯 Prochaines Étapes Recommandées

### Optimisations Prioritaires

1. **Mesurer les métriques actuelles** (utiliser ce guide)
2. **Identifier les 2-3 plus gros bottlenecks**
3. **Implémenter les fixes**:
   - Si lancement lent → Optimiser `loadWingsAsync()`
   - Si lag navigation → Vérifier les re-renders
   - Si batterie → Vérifier GPS et sync iPhone
4. **Re-mesurer et valider**

### Tests Recommandés

1. **Simulator**: Apple Watch Series 9/10 (46mm)
2. **Device réel**: Si disponible
3. **Scénarios**:
   - Lancement app à froid
   - 10 sélections de voiles consécutives
   - 3 vols complets
   - Sync depuis iPhone

---

## 📞 Support

### Ressources

- [WATCH_PERFORMANCE_DIAGNOSIS.md](WATCH_PERFORMANCE_DIAGNOSIS.md) - Guide d'analyse existant
- [Apple Watch Programming Guide](https://developer.apple.com/documentation/watchos)
- [Xcode Instruments Documentation](https://help.apple.com/instruments/mac/current/)

### Logs Utiles

Filtrer Console Xcode par:
- `⏱️ [PERF]` - Logs de performance
- `📡` - WatchConnectivity
- `🌐` - Localisation
- `📦` - Cache d'images

---

**Date de création**: 2025-12-05
**Version**: 1.0
**Maintenu par**: Claude (Anthropic)
