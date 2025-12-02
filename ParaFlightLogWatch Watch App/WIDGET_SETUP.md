# Configuration du Widget Apple Watch

Le code du widget est déjà prêt dans `ParaFlightLogWidget.swift`, mais pour qu'il fonctionne comme complication sur le cadran Apple Watch, il faut créer un **Widget Extension** séparé.

## Étapes pour activer le widget :

### 1. Créer un Widget Extension

Dans Xcode :
1. **File > New > Target**
2. Sélectionner **Watch Widget Extension** (watchOS)
3. Nommer l'extension : `ParaFlightLogWidgetExtension`
4. Décocher "Include Configuration Intent" (optionnel)
5. Cliquer sur **Finish**

### 2. Remplacer le code généré

1. Supprimer le fichier généré automatiquement par Xcode
2. Ajouter `ParaFlightLogWidget.swift` au target `ParaFlightLogWidgetExtension`
3. Ajouter aussi `SharedModels.swift` au target pour avoir accès à `WingDTO` et `FlightDTO`
4. Dans `ParaFlightLogWidget.swift`, décommenter le `@main` devant la struct `ParaFlightLogWidget`

### 3. Configurer le Widget Bundle

Créer un fichier `WidgetBundle.swift` dans l'extension :

```swift
import WidgetKit
import SwiftUI

@main
struct ParaFlightLogWidgetBundle: WidgetBundle {
    var body: some Widget {
        ParaFlightLogWidget()
    }
}
```

### 4. Compiler et tester

1. Sélectionner le scheme `ParaFlightLogWidgetExtension`
2. Compiler et lancer sur simulateur/device
3. Sur l'Apple Watch, maintenir appuyé sur le cadran
4. Toucher "Modifier"
5. Choisir une complication et sélectionner "ParaFlightLog"

## Types de complications disponibles

Le widget supporte 3 familles de complications :

- **Circular** (`.accessoryCircular`) : Icône avec timer si vol en cours
- **Rectangular** (`.accessoryRectangular`) : Affichage complet avec nom de voile et durée
- **Inline** (`.accessoryInline`) : Simple texte avec icône

## Fonctionnalités futures

Pour l'instant, le widget affiche un état statique. Pour le rendre dynamique :

1. Utiliser un **App Group** pour partager les données entre l'app et le widget
2. Mettre à jour le widget avec `WidgetCenter.shared.reloadAllTimelines()` quand un vol commence/se termine
3. Utiliser `UserDefaults(suiteName: "group.com.xavierkain.ParaFlightLog")` pour partager l'état du vol

## Code à ajouter pour le partage de données

Dans `FlightTimerView.startFlight()` :
```swift
// Enregistrer l'état dans App Group
let defaults = UserDefaults(suiteName: "group.com.xavierkain.ParaFlightLog")
defaults?.set(true, forKey: "isFlying")
defaults?.set(Date(), forKey: "flightStartDate")
defaults?.set(selectedWing?.name, forKey: "wingName")

// Notifier le widget
WidgetCenter.shared.reloadAllTimelines()
```

Dans `FlightTimerView.stopFlight()` :
```swift
// Réinitialiser l'état
let defaults = UserDefaults(suiteName: "group.com.xavierkain.ParaFlightLog")
defaults?.set(false, forKey: "isFlying")
defaults?.removeObject(forKey: "flightStartDate")
defaults?.removeObject(forKey: "wingName")

// Notifier le widget
WidgetCenter.shared.reloadAllTimelines()
```

Dans le `FlightWidgetProvider.getTimeline()` :
```swift
let defaults = UserDefaults(suiteName: "group.com.xavierkain.ParaFlightLog")
let isFlying = defaults?.bool(forKey: "isFlying") ?? false
let startDate = defaults?.object(forKey: "flightStartDate") as? Date
let wingName = defaults?.string(forKey: "wingName")

var elapsedTime = "00:00"
if isFlying, let start = startDate {
    let elapsed = Int(Date().timeIntervalSince(start))
    let minutes = elapsed / 60
    let seconds = elapsed % 60
    elapsedTime = String(format: "%02d:%02d", minutes, seconds)
}

let entry = FlightEntry(
    date: Date(),
    isFlying: isFlying,
    elapsedTime: elapsedTime,
    wingName: wingName
)
```
