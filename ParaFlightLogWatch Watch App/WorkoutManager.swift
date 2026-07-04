//
//  WorkoutManager.swift
//  ParaFlightLogWatch Watch App
//
//  Manages the HealthKit workout session used to enable Water Lock
//  Target: Watch only
//

import Foundation
import HealthKit
import WatchKit

final class WorkoutManager {
    static let shared = WorkoutManager()

    private var healthStore: HKHealthStore?
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    private init() {
        // Check that HealthKit is available
        guard HKHealthStore.isHealthDataAvailable() else {
            watchLogWarning("HealthKit not available on this device", category: .workout)
            return
        }

        healthStore = HKHealthStore()
    }

    // MARK: - Authorization

    /// Requests HealthKit authorization
    func requestAuthorization() async -> Bool {
        guard let healthStore = healthStore else { return false }

        // Data types to share/read (minimal for the workout)
        let typesToShare: Set<HKSampleType> = [
            HKObjectType.workoutType()
        ]

        let typesToRead: Set<HKObjectType> = [
            HKObjectType.workoutType()
        ]

        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
            watchLogInfo("HealthKit authorization granted", category: .workout)
            return true
        } catch {
            watchLogError("HealthKit authorization failed: \(error.localizedDescription)", category: .workout)
            return false
        }
    }

    // MARK: - Workout Session

    /// Starts a workout session to allow Water Lock
    func startWorkoutSession() async {
        guard let healthStore = healthStore else {
            watchLogWarning("HealthStore not available", category: .workout)
            return
        }

        // If a session is already active, do nothing
        guard workoutSession == nil else {
            watchLogDebug("Workout session already active", category: .workout)
            return
        }

        // Configure the workout (paragliding = "Other")
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor

        do {
            // Create the session
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()

            // Configure the builder
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)

            // Start the session
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())

            await MainActor.run {
                self.workoutSession = session
                self.workoutBuilder = builder
            }

            watchLogInfo("Workout session started", category: .workout)

            // Now Water Lock can be enabled
            await MainActor.run {
                if WatchSettings.shared.autoWaterLockEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        watchLogDebug("Activating Water Lock with workout session", category: .workout)
                        WKInterfaceDevice.current().enableWaterLock()
                    }
                }
            }

        } catch {
            watchLogError("Failed to start workout session: \(error.localizedDescription)", category: .workout)
        }
    }

    /// Properly ends the workout session when the flight stops:
    /// end the session, end data collection, then discard the workout
    /// (paragliding flights are not saved to Health)
    func stopWorkoutSession() async {
        guard let session = workoutSession, let builder = workoutBuilder else {
            // No active session - normal when autoWaterLockEnabled was false
            return
        }

        // End the session
        session.end()

        do {
            try await builder.endCollection(at: Date())
            // Discard instead of finishWorkout(): nothing is saved to Health
            builder.discardWorkout()
            watchLogInfo("Workout session ended and discarded", category: .workout)
        } catch {
            // Still discard so the builder does not leak a half-open workout
            builder.discardWorkout()
            watchLogError("Failed to end workout collection: \(error.localizedDescription)", category: .workout)
        }

        await MainActor.run {
            self.workoutSession = nil
            self.workoutBuilder = nil
        }
    }
}
