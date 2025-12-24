//
//  StatsCache.swift
//  ParaFlightLog
//
//  Système de cache pour les statistiques de vol
//  Pré-calcule et met en cache les stats pour améliorer les performances
//  Target: iOS only
//

import Foundation
import SwiftUI

@Observable
final class StatsCache {
    // Cache des statistiques
    private(set) var totalFlightHours: Double = 0.0
    private(set) var totalFlightCount: Int = 0
    private(set) var hoursByWing: [UUID: Double] = [:]
    private(set) var hoursBySpot: [String: Double] = [:]
    private(set) var flightCountByWing: [UUID: Int] = [:]
    private(set) var flightCountBySpot: [String: Int] = [:]

    // État du cache
    private(set) var isLoading: Bool = false
    private(set) var lastUpdate: Date?
    private(set) var isValid: Bool = false

    // Référence au DataController (weak pour éviter les cycles de rétention)
    weak var dataController: DataController?

    // File d'attente pour les calculs asynchrones
    private let queue = DispatchQueue(label: "com.xavierkain.ParaFlightLog.StatsCache", qos: .userInitiated)

    init() {
        // Le cache sera initialisé lors de l'injection du dataController
    }

    // MARK: - Calcul des statistiques

    /// Calcule toutes les statistiques en arrière-plan
    func refreshCache() {
        guard let dataController = dataController else {
            logWarning("DataController not available for stats cache", category: .stats)
            return
        }

        isLoading = true

        queue.async { [weak self] in
            guard let self = self else { return }

            // Récupérer tous les vols
            let flights = dataController.fetchFlights()

            // Calculer toutes les stats
            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            let hours = Double(totalSeconds) / 3600.0
            let count = flights.count

            // Stats par voile
            var wingHours: [UUID: Double] = [:]
            var wingCounts: [UUID: Int] = [:]
            for flight in flights {
                guard let wingId = flight.wing?.id else { continue }
                let flightHours = Double(flight.durationSeconds) / 3600.0
                wingHours[wingId, default: 0.0] += flightHours
                wingCounts[wingId, default: 0] += 1
            }

            // Stats par spot
            var spotHours: [String: Double] = [:]
            var spotCounts: [String: Int] = [:]
            for flight in flights {
                let spot = flight.spotName ?? "Unknown"
                let flightHours = Double(flight.durationSeconds) / 3600.0
                spotHours[spot, default: 0.0] += flightHours
                spotCounts[spot, default: 0] += 1
            }

            // Mettre à jour le cache sur le thread principal
            DispatchQueue.main.async {
                self.totalFlightHours = hours
                self.totalFlightCount = count
                self.hoursByWing = wingHours
                self.hoursBySpot = spotHours
                self.flightCountByWing = wingCounts
                self.flightCountBySpot = spotCounts
                self.lastUpdate = Date()
                self.isValid = true
                self.isLoading = false

                logDebug("Stats cache refreshed: \(count) flights, \(String(format: "%.2f", hours))h total", category: .stats)
            }
        }
    }

    /// Invalide le cache (à appeler lors de modifications de données)
    func invalidate() {
        isValid = false
        lastUpdate = nil
        logDebug("Stats cache invalidated", category: .stats)
    }

    /// Rafraîchit le cache seulement s'il n'est pas valide
    func refreshIfNeeded() {
        guard !isValid else { return }
        refreshCache()
    }

    // MARK: - Méthodes d'accès aux statistiques

    /// Récupère les heures de vol pour une voile spécifique
    func hoursForWing(_ wingId: UUID) -> Double {
        refreshIfNeeded()
        return hoursByWing[wingId] ?? 0.0
    }

    /// Récupère le nombre de vols pour une voile spécifique
    func flightCountForWing(_ wingId: UUID) -> Int {
        refreshIfNeeded()
        return flightCountByWing[wingId] ?? 0
    }

    /// Récupère les heures de vol pour un spot spécifique
    func hoursForSpot(_ spotName: String) -> Double {
        refreshIfNeeded()
        return hoursBySpot[spotName] ?? 0.0
    }

    /// Récupère le nombre de vols pour un spot spécifique
    func flightCountForSpot(_ spotName: String) -> Int {
        refreshIfNeeded()
        return flightCountBySpot[spotName] ?? 0
    }

    /// Formatte un nombre d'heures en string lisible (ex: 12.5 → "12h30")
    func formatHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h)h"
    }
}
