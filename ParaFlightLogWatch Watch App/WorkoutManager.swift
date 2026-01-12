//
//  WorkoutManager.swift
//  ParaFlightLogWatch Watch App
//
//  Gère les sessions workout HealthKit pour activer le Water Lock
//  Target: Watch only
//

import Foundation
import HealthKit
import WatchKit

@Observable
final class WorkoutManager: NSObject {
    static let shared = WorkoutManager()

    private var healthStore: HKHealthStore?
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    var isWorkoutActive: Bool = false
    var isAuthorized: Bool = false

    /// Flag pour activer le Water Lock une fois la session running
    private var shouldEnableWaterLockWhenRunning: Bool = false

    private override init() {
        super.init()

        // Vérifier si HealthKit est disponible
        guard HKHealthStore.isHealthDataAvailable() else {
            watchLogWarning("HealthKit not available on this device", category: .workout)
            return
        }

        healthStore = HKHealthStore()
    }

    // MARK: - Authorization

    /// Demande l'autorisation HealthKit
    func requestAuthorization() async -> Bool {
        guard let healthStore = healthStore else { return false }

        // Types de données à partager/lire (minimal pour le workout)
        let typesToShare: Set<HKSampleType> = [
            HKObjectType.workoutType()
        ]

        let typesToRead: Set<HKObjectType> = [
            HKObjectType.workoutType()
        ]

        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
            await MainActor.run {
                isAuthorized = true
            }
            watchLogInfo("HealthKit authorization granted", category: .workout)
            return true
        } catch {
            watchLogError("HealthKit authorization failed: \(error.localizedDescription)", category: .workout)
            return false
        }
    }

    // MARK: - Workout Session

    /// Démarre une session workout pour permettre le Water Lock
    func startWorkoutSession() async {
        guard let healthStore = healthStore else {
            watchLogWarning("HealthStore not available", category: .workout)
            return
        }

        // Si une session est déjà active, ne rien faire
        guard workoutSession == nil else {
            watchLogDebug("Workout session already active", category: .workout)
            return
        }

        // Configurer le workout (parapente = "Other")
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor

        do {
            // Créer la session
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()

            // Configurer le delegate pour savoir quand la session est vraiment running
            session.delegate = self

            // Configurer le builder
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)

            // Marquer qu'on veut activer le Water Lock quand la session sera running
            shouldEnableWaterLockWhenRunning = WatchSettings.shared.autoWaterLockEnabled

            await MainActor.run {
                self.workoutSession = session
                self.workoutBuilder = builder
            }

            // Démarrer la session
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())

            await MainActor.run {
                self.isWorkoutActive = true
            }

            watchLogInfo("Workout session started (required for continuous GPS)", category: .workout)

        } catch {
            watchLogError("Failed to start workout session: \(error.localizedDescription)", category: .workout)
        }
    }

    /// Arrête la session workout
    func stopWorkoutSession() async {
        guard let session = workoutSession, let builder = workoutBuilder else {
            // Pas de session active - c'est normal si autoWaterLockEnabled était false
            return
        }

        // Arrêter la session
        session.end()

        do {
            try await builder.endCollection(at: Date())
            // Optionnel: sauvegarder le workout (on peut skip pour parapente)
            // try await builder.finishWorkout()
            watchLogInfo("Workout session ended", category: .workout)
        } catch {
            watchLogError("Failed to end workout session: \(error.localizedDescription)", category: .workout)
        }

        await MainActor.run {
            self.workoutSession = nil
            self.workoutBuilder = nil
            self.isWorkoutActive = false
        }
    }

    /// Arrête la session sans async (pour les cas où on ne peut pas await)
    func endWorkoutSession() {
        workoutSession?.end()
        workoutSession = nil
        workoutBuilder = nil
        isWorkoutActive = false
        shouldEnableWaterLockWhenRunning = false
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        watchLogDebug("Workout session state changed: \(fromState.rawValue) -> \(toState.rawValue)", category: .workout)

        // Activer le Water Lock seulement quand la session passe à "running"
        if toState == .running && shouldEnableWaterLockWhenRunning {
            shouldEnableWaterLockWhenRunning = false
            // Attendre un court instant pour que le système enregistre vraiment la session
            // Le callback arrive parfois avant que watchOS ait fini d'initialiser la session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WKInterfaceDevice.current().enableWaterLock()
                watchLogInfo("Water Lock activated (session is now running)", category: .workout)
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        watchLogError("Workout session failed: \(error.localizedDescription)", category: .workout)
    }
}
