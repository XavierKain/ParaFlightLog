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

    private override init() {
        super.init()

        // Vérifier si HealthKit est disponible
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚠️ HealthKit not available on this device")
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
            print("✅ HealthKit authorization granted")
            return true
        } catch {
            print("❌ HealthKit authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Workout Session

    /// Pré-initialise la session workout en avance pour éviter le lag au premier vol
    /// Cette méthode crée la configuration mais ne démarre pas la session
    func prepareWorkoutSession() async {
        guard let healthStore = healthStore else { return }

        // Pré-créer la configuration pour que le premier startWorkoutSession soit instantané
        // La première création de HKWorkoutConfiguration peut prendre du temps
        _ = HKWorkoutConfiguration()

        print("✅ Workout session pre-initialized")
    }

    /// Démarre une session workout pour permettre le Water Lock
    func startWorkoutSession() async {
        guard let healthStore = healthStore else {
            print("⚠️ HealthStore not available")
            return
        }

        // Si une session est déjà active, ne rien faire
        guard workoutSession == nil else {
            print("⚠️ Workout session already active")
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

            // Configurer le builder
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)

            // Démarrer la session
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())

            await MainActor.run {
                self.workoutSession = session
                self.workoutBuilder = builder
                self.isWorkoutActive = true
            }

            print("✅ Workout session started")

            // Maintenant on peut activer le Water Lock
            await MainActor.run {
                if WatchSettings.shared.autoWaterLockEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("🔒 Activating Water Lock with workout session...")
                        WKInterfaceDevice.current().enableWaterLock()
                    }
                }
            }

        } catch {
            print("❌ Failed to start workout session: \(error.localizedDescription)")
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
            print("✅ Workout session ended")
        } catch {
            print("❌ Failed to end workout session: \(error.localizedDescription)")
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
    }
}
