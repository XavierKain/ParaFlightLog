# Synchronisation Bidirectionnelle iPhone ↔ Apple Watch

## Vue d'ensemble

Ce document décrit l'implémentation de la synchronisation instantanée des settings entre l'iPhone et l'Apple Watch dans l'application SoarX/ParaFlightLog.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           iPhone                                     │
│  ┌─────────────────┐    ┌──────────────────────┐    ┌────────────┐ │
│  │ WatchSettingsView│◄──►│WatchConnectivityManager│◄──►│UserDefaults│ │
│  │   (@State vars) │    │                      │    │            │ │
│  └────────┬────────┘    └──────────┬───────────┘    └────────────┘ │
│           │                        │                                │
│           │ .onReceive             │ sendWatchSettings()            │
│           │ (.watchSettingsDidUpdate)│                              │
│           ▼                        ▼                                │
└───────────────────────────────WCSession────────────────────────────┘
                                    │
                                    │ Application Context
                                    │ / sendMessage
                                    ▼
┌───────────────────────────────WCSession────────────────────────────┐
│                           Apple Watch                               │
│  ┌─────────────────┐    ┌──────────────────────┐    ┌────────────┐ │
│  │ WatchSettingsView│◄──►│   WatchSettings      │◄──►│UserDefaults│ │
│  │   (@State vars) │    │   (Singleton)        │    │            │ │
│  └────────┬────────┘    └──────────┬───────────┘    └────────────┘ │
│           │                        │                                │
│           │ .onReceive             │ updateFromContext()            │
│           │ (.watchSettingsUpdatedFromPhone)                        │
│           ▼                        ▼                                │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              WatchConnectivityManager                         │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Flux de données

### iPhone → Watch

1. L'utilisateur modifie un toggle dans `WatchSettingsView` (iPhone)
2. Le `@State` local change et déclenche `.onChange`
3. `.onChange` sauvegarde dans `UserDefaults` ET appelle `watchManager.sendWatchSettings()`
4. `WatchConnectivityManager` envoie via `updateApplicationContext()` ou `sendMessage()`
5. Sur la Watch, `WatchConnectivityManager.session(_:didReceiveApplicationContext:)` reçoit les données
6. Il appelle `WatchSettings.shared.updateFromContext(context)`
7. `updateFromContext()` met à jour les propriétés sur le `MainActor` et poste une notification
8. `WatchSettingsView` (Watch) reçoit la notification via `.onReceive` et rafraîchit ses `@State`

### Watch → iPhone

1. L'utilisateur modifie un toggle dans `WatchSettingsView` (Watch)
2. Le `@State` local change et déclenche `.onChange`
3. `.onChange` met à jour `WatchSettings.shared` qui sauvegarde dans `UserDefaults`
4. `WatchSettings.notifySettingsChanged()` appelle `WatchConnectivityManager.sendSettingsToPhone()`
5. Les données sont envoyées via `sendMessage()` ou `transferUserInfo()`
6. Sur l'iPhone, `WatchConnectivityManager.session(_:didReceiveMessage:)` reçoit les données
7. Il sauvegarde dans `UserDefaults` et poste `.watchSettingsDidUpdate`
8. `WatchSettingsView` (iPhone) reçoit la notification via `.onReceive` et rafraîchit ses `@State`

## Fichiers impliqués

### iPhone

| Fichier | Rôle |
|---------|------|
| `Views/ProfileViews.swift` | `WatchSettingsView` - UI des settings Watch |
| `WatchConnectivityManager.swift` | Gestion WCSession, envoi/réception messages |
| `Constants.swift` | `UserDefaultsKeys` et `Notification.Name.watchSettingsDidUpdate` |

### Watch

| Fichier | Rôle |
|---------|------|
| `ContentView.swift` | `WatchSettingsView` - UI des settings |
| `WatchSettings.swift` | Singleton `@Observable` pour la gestion des settings |
| `WatchConnectivityManager.swift` | Gestion WCSession côté Watch |

## Patterns clés

### 1. Variables @State locales + Notification

**Problème**: Les bindings directs vers `UserDefaults` ou singletons ne déclenchent pas toujours les mises à jour SwiftUI.

**Solution**: Utiliser des `@State` locales synchronisées via notifications.

```swift
struct WatchSettingsView: View {
    // États locaux pour un rafraîchissement instantané
    @State private var autoWaterLock: Bool = UserDefaults.standard.bool(forKey: "key")

    var body: some View {
        Toggle(isOn: $autoWaterLock) { ... }
            .onChange(of: autoWaterLock) { _, newValue in
                // Sauvegarder ET synchroniser
                UserDefaults.standard.set(newValue, forKey: "key")
                watchManager.sendWatchSettings(...)
            }
            .onAppear {
                // IMPORTANT: Rafraîchir à chaque apparition de la vue
                // Les @State peuvent être désynchronisées si la vue est recréée
                autoWaterLock = UserDefaults.standard.bool(forKey: "key")
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchSettingsDidUpdate)) { _ in
                // Rafraîchir depuis la source de vérité
                autoWaterLock = UserDefaults.standard.bool(forKey: "key")
            }
    }
}
```

### 2. MainActor pour les mises à jour UI

**Problème**: Les callbacks WatchConnectivity sont appelés sur des threads background.

**Solution**: Envelopper les mises à jour de propriétés `@Observable` dans `Task { @MainActor in }`.

```swift
func updateFromContext(_ context: [String: Any]) {
    // Extraire les valeurs AVANT d'entrer dans le MainActor
    let newValue = context["key"] as? Bool

    Task { @MainActor in
        if let value = newValue {
            self.observableProperty = value
        }
        NotificationCenter.default.post(name: .settingsUpdated, object: nil)
    }
}
```

### 3. Flag anti-boucle

**Problème**: Recevoir un setting de l'iPhone et le renvoyer immédiatement crée une boucle infinie.

**Solution**: Un flag `isUpdatingFromPhone` qui bloque l'envoi pendant la réception.

```swift
private var isUpdatingFromPhone = false

func updateFromContext(_ context: [String: Any]) {
    isUpdatingFromPhone = true
    defer { isUpdatingFromPhone = false }

    // ... mettre à jour les propriétés
}

private func notifySettingsChanged() {
    guard !isUpdatingFromPhone else { return }
    // ... envoyer vers l'autre appareil
}
```

### 4. Persistance avec UserDefaults + didSet

```swift
var autoWaterLockEnabled: Bool {
    didSet {
        UserDefaults.standard.set(autoWaterLockEnabled, forKey: "autoWaterLockEnabled")
        notifySettingsChanged()
    }
}

private init() {
    // Charger au démarrage
    self.autoWaterLockEnabled = UserDefaults.standard.object(forKey: "autoWaterLockEnabled") as? Bool ?? false
}
```

## Notifications utilisées

| Notification | Émise par | Écoutée par | Quand |
|--------------|-----------|-------------|-------|
| `.watchSettingsDidUpdate` | iPhone `WatchConnectivityManager` | iPhone `WatchSettingsView` | Settings reçus de la Watch |
| `.watchSettingsUpdatedFromPhone` | Watch `WatchSettings` | Watch `WatchSettingsView` | Settings reçus de l'iPhone |

## Erreurs courantes et solutions

### "Publishing changes from background threads is not allowed"

**Cause**: Modification de propriétés `@Observable` depuis un callback WatchConnectivity (thread background).

**Solution**: Utiliser `Task { @MainActor in }` pour les mises à jour.

### Les settings ne se synchronisent pas

**Vérifications**:
1. `WCSession.default.isReachable` - L'autre appareil est-il joignable ?
2. `WCSession.default.activationState == .activated` - La session est-elle active ?
3. Les clés dans le dictionnaire correspondent-elles (`watchAutoWaterLock`, etc.) ?

### L'UI ne se met pas à jour

**Vérifications**:
1. La notification est-elle postée sur le MainActor ?
2. Le `.onReceive` est-il bien attaché à la vue ?
3. Les `@State` sont-elles rafraîchies dans le handler de notification ?
4. **Y a-t-il un `.onAppear` pour rafraîchir les valeurs ?** (Les @State peuvent être désynchronisées quand on quitte/revient sur la vue)

## Checklist pour ajouter un nouveau setting synchronisé

1. **iPhone - UserDefaultsKeys** : Ajouter la clé dans `Constants.swift`
2. **iPhone - WatchConnectivityManager** : Ajouter le paramètre à `sendWatchSettings()`
3. **iPhone - WatchSettingsView** : Ajouter `@State`, Toggle, `.onChange`
4. **Watch - WatchSettings** : Ajouter la propriété avec `didSet` et persistance
5. **Watch - WatchSettings.updateFromContext()** : Parser la nouvelle clé
6. **Watch - WatchSettingsView** : Ajouter `@State`, Toggle, `.onChange`
7. **Tester** : iPhone→Watch ET Watch→iPhone

## Code de référence

### iPhone - WatchSettingsView (ProfileViews.swift)

```swift
struct WatchSettingsView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager

    @State private var autoWaterLock: Bool = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
    @State private var allowSessionDismiss: Bool = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true

    var body: some View {
        List {
            Toggle(isOn: $autoWaterLock) {
                Label("Water Lock auto", systemImage: "drop.fill")
            }
            .onChange(of: autoWaterLock) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAutoWaterLock)
                watchManager.sendWatchSettings(autoWaterLock: newValue, allowSessionDismiss: allowSessionDismiss)
            }

            // ... autres toggles
        }
        .onAppear {
            // IMPORTANT: Rafraîchir à chaque apparition pour éviter les valeurs obsolètes
            autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
            allowSessionDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchSettingsDidUpdate)) { _ in
            autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
            allowSessionDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
        }
    }
}
```

### Watch - WatchSettings.swift

```swift
@Observable
final class WatchSettings {
    static let shared = WatchSettings()

    private var isUpdatingFromPhone = false

    var autoWaterLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoWaterLockEnabled, forKey: "autoWaterLockEnabled")
            notifySettingsChanged()
        }
    }

    private init() {
        self.autoWaterLockEnabled = UserDefaults.standard.object(forKey: "autoWaterLockEnabled") as? Bool ?? false
    }

    private func notifySettingsChanged() {
        guard !isUpdatingFromPhone else { return }
        WatchConnectivityManager.shared.sendSettingsToPhone(...)
    }

    func updateFromContext(_ context: [String: Any]) {
        let newAutoWaterLock = context["watchAutoWaterLock"] as? Bool

        Task { @MainActor in
            isUpdatingFromPhone = true
            defer { isUpdatingFromPhone = false }

            if let value = newAutoWaterLock {
                autoWaterLockEnabled = value
            }

            NotificationCenter.default.post(name: .watchSettingsUpdatedFromPhone, object: nil)
        }
    }
}
```

### Watch - WatchSettingsView (ContentView.swift)

```swift
struct WatchSettingsView: View {
    @State private var autoWaterLock: Bool = WatchSettings.shared.autoWaterLockEnabled

    var body: some View {
        Toggle(isOn: $autoWaterLock) {
            Label("Water Lock", systemImage: "drop.fill")
        }
        .onChange(of: autoWaterLock) { _, newValue in
            WatchSettings.shared.autoWaterLockEnabled = newValue
        }
        .onAppear {
            autoWaterLock = WatchSettings.shared.autoWaterLockEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchSettingsUpdatedFromPhone)) { _ in
            autoWaterLock = WatchSettings.shared.autoWaterLockEnabled
        }
    }
}
```

---

*Documentation créée le 9 janvier 2026 pour SoarX/ParaFlightLog*
