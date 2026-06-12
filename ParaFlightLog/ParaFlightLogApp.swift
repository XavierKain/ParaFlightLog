//
//  ParaFlightLogApp.swift
//  SoarX
//
//  App principale iOS avec setup SwiftData + injection des services
//  Target: iOS only
//

import SwiftUI
import SwiftData

@main
struct SoarXApp: App {
    // AppDelegate pour gérer les notifications locales
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Services - DataController et LocationService sont des instances propres à l'app
    @State private var dataController = DataController()
    @State private var locationService = LocationService()

    // Singletons - on utilise directement les instances partagées sans les stocker en @State
    private var watchConnectivityManager: WatchConnectivityManager { WatchConnectivityManager.shared }
    private var localizationManager: LocalizationManager { LocalizationManager.shared }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(dataController)
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
                .environment(\.locale, localizationManager.locale)
        }
        .modelContainer(dataController.modelContainer)
    }
}

// Vue wrapper pour gérer l'initialisation
private struct IOSRootView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocationService.self) private var locationService
    @Environment(LocalizationManager.self) private var localizationManager

    @State private var hasInitialized = false

    var body: some View {
        ContentView()
            .environment(\.locale, localizationManager.locale)
            .onAppear {
                // Configurer les bonnes références (une seule fois)
                if !hasInitialized {
                    watchManager.dataController = dataController
                    watchManager.locationService = locationService
                    dataController.watchConnectivityManager = watchManager

                    // Activer la session APRÈS injection
                    watchManager.activateSession()

                    locationService.requestAuthorization()

                    // Forcer l'envoi des voiles à la Watch après activation
                    DispatchQueue.main.asyncAfter(deadline: .now() + WatchSyncConstants.initialSyncDelay) {
                        watchManager.sendWingsToWatch()
                        logInfo("Manually triggered wing sync to Watch", category: .watchSync)
                    }

                    hasInitialized = true

                    #if DEBUG
                    runDebugBackupImportIfRequested()
                    #endif
                }
            }
    }

    #if DEBUG
    /// Hook de test : `-importBackupPath <chemin>` en argument de lancement déclenche
    /// un import de backup au démarrage (utilisé par les vérifications automatisées).
    private func runDebugBackupImportIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-importBackupPath"), idx + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[idx + 1])
        ZipBackup.importFromZip(zipURL: url, dataController: dataController) { result in
            switch result {
            case .success(let summary):
                logInfo("DEBUG import OK: \(summary.replacingOccurrences(of: "\n", with: " | "))", category: .dataController)
            case .failure(let error):
                logError("DEBUG import FAILED: \(error.localizedDescription)", category: .dataController)
            }
        }
    }
    #endif
}
