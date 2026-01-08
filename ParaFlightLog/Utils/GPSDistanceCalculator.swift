//
//  GPSDistanceCalculator.swift
//  ParaFlightLog
//
//  Utilitaire de calcul de distance GPS précis
//  Suit la trace GPS avec filtrage intelligent des anomalies
//  Target: iOS + Watch
//

import Foundation
import CoreLocation

/// Calculateur de distance GPS avec filtrage intelligent
class GPSDistanceCalculator {

    // MARK: - Distance Calculation

    /// Calcule la distance totale en suivant la trace GPS avec filtrage des anomalies
    /// - Parameters:
    ///   - points: Points GPS de la trace
    ///   - filterOutliers: Active/désactive le filtrage des anomalies (défaut: true)
    /// - Returns: Distance totale en mètres
    static func calculateTrackDistance(
        points: [GPSTrackPoint],
        filterOutliers: Bool = true
    ) -> Double {
        guard points.count >= 2 else { return 0 }

        let filtered = filterOutliers ? removeOutliers(points) : points
        var totalDistance: Double = 0

        for i in 1..<filtered.count {
            let prev = filtered[i-1]
            let curr = filtered[i]
            totalDistance += haversineDistance(
                lat1: prev.latitude, lon1: prev.longitude,
                lat2: curr.latitude, lon2: curr.longitude
            )
        }

        return totalDistance
    }

    // MARK: - Haversine Distance

    /// Calcule la distance entre deux points GPS avec la formule de Haversine
    /// - Parameters:
    ///   - lat1: Latitude du premier point (degrés)
    ///   - lon1: Longitude du premier point (degrés)
    ///   - lat2: Latitude du deuxième point (degrés)
    ///   - lon2: Longitude du deuxième point (degrés)
    /// - Returns: Distance en mètres
    static func haversineDistance(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let R = 6371000.0 // Rayon de la Terre en mètres
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }

    // MARK: - Outlier Filtering

    /// Filtre les anomalies GPS (vitesses irréalistes, précision médiocre, bruit GPS)
    /// - Parameter points: Points GPS à filtrer
    /// - Returns: Points filtrés
    static func removeOutliers(_ points: [GPSTrackPoint]) -> [GPSTrackPoint] {
        var filtered: [GPSTrackPoint] = []

        for i in 0..<points.count {
            // Premier point toujours inclus
            if i == 0 {
                filtered.append(points[i])
                continue
            }

            let prev = filtered.last!
            let curr = points[i]

            // Calculer la distance et la vitesse entre les deux points
            let distance = haversineDistance(
                lat1: prev.latitude, lon1: prev.longitude,
                lat2: curr.latitude, lon2: curr.longitude
            )
            let timeInterval = curr.timestamp.timeIntervalSince(prev.timestamp)

            guard timeInterval > 0 else { continue }

            let speed = distance / timeInterval // m/s
            let speedKmh = speed * 3.6

            // Filtrer les vitesses irréalistes (>150 km/h pour le parapente)
            if speedKmh > 150 {
                logDebug("GPS: Filtered point with speed \(Int(speedKmh)) km/h", category: .general)
                continue
            }

            // Filtrer les points trop proches (<2m, probablement du bruit GPS)
            if distance < 2 {
                continue
            }

            // Filtrer les points avec mauvaise précision (>15m)
            // Précision de 15m permet de garder des points raisonnables tout en filtrant les erreurs GPS
            if let accuracy = curr.accuracy, accuracy > 15 {
                logDebug("GPS: Filtered point with accuracy \(Int(accuracy))m", category: .general)
                continue
            }

            filtered.append(curr)
        }

        logInfo("GPS: Filtered \(points.count - filtered.count) outlier points from \(points.count) total", category: .general)

        return filtered
    }

    // MARK: - Simplification (Douglas-Peucker)

    /// Simplifie une trace GPS en conservant les points importants
    /// Utilise l'algorithme de Douglas-Peucker
    /// - Parameters:
    ///   - points: Points GPS à simplifier
    ///   - epsilon: Tolérance en mètres (défaut: 5m)
    /// - Returns: Points simplifiés
    static func simplifyTrack(
        _ points: [GPSTrackPoint],
        epsilon: Double = 5.0
    ) -> [GPSTrackPoint] {
        guard points.count > 2 else { return points }

        // Trouver le point le plus éloigné de la ligne start-end
        var maxDistance: Double = 0
        var maxIndex = 0
        let start = points.first!
        let end = points.last!

        for i in 1..<(points.count - 1) {
            let point = points[i]
            let distance = perpendicularDistance(
                point: point,
                lineStart: start,
                lineEnd: end
            )
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = i
            }
        }

        // Si le point le plus éloigné est au-delà de epsilon, récurser
        if maxDistance > epsilon {
            // Simplifier récursivement les deux segments
            let left = Array(points[0...maxIndex])
            let right = Array(points[maxIndex..<points.count])

            let leftSimplified = simplifyTrack(left, epsilon: epsilon)
            let rightSimplified = simplifyTrack(right, epsilon: epsilon)

            // Combiner les résultats (en évitant de dupliquer le point central)
            var result = leftSimplified
            result.append(contentsOf: rightSimplified.dropFirst())
            return result
        } else {
            // Sinon, ne garder que start et end
            return [start, end]
        }
    }

    /// Calcule la distance perpendiculaire d'un point à une ligne
    private static func perpendicularDistance(
        point: GPSTrackPoint,
        lineStart: GPSTrackPoint,
        lineEnd: GPSTrackPoint
    ) -> Double {
        // Pour simplifier, on utilise une approximation euclidienne locale
        // (suffisante pour de petites distances)
        let x0 = point.latitude
        let y0 = point.longitude
        let x1 = lineStart.latitude
        let y1 = lineStart.longitude
        let x2 = lineEnd.latitude
        let y2 = lineEnd.longitude

        let dx = x2 - x1
        let dy = y2 - y1

        let numerator = abs(dy * x0 - dx * y0 + x2 * y1 - y2 * x1)
        let denominator = sqrt(dx * dx + dy * dy)

        guard denominator > 0 else { return 0 }

        // Convertir en mètres (approximation)
        let distanceInDegrees = numerator / denominator
        return distanceInDegrees * 111000 // 1 degré ≈ 111 km
    }

    // MARK: - Helper Functions

    /// Log de débogage
    private static func logDebug(_ message: String, category: LogCategory) {
        #if DEBUG
        print("[DEBUG] \(message)")
        #endif
    }

    /// Log d'information
    private static func logInfo(_ message: String, category: LogCategory) {
        print("[INFO] \(message)")
    }
}
