//
//  WindEstimator.swift
//  ParaFlightLog
//
//  Algorithmes d'estimation du vent basés sur les traces GPS
//  Target: iOS only
//

import Foundation
import CoreLocation

// MARK: - Wind Estimation Result

/// Résultat de l'estimation du vent
struct WindEstimation {
    let speed: Double           // Vitesse moyenne en m/s
    let speedMin: Double        // Fourchette basse en m/s
    let speedMax: Double        // Fourchette haute en m/s
    let direction: Double       // Direction en degrés (d'où vient le vent, 0-360)
    let confidence: Double      // Indice de confiance (0.0 - 1.0)
    let method: String          // Méthode utilisée

    /// Vitesse en km/h
    var speedKmh: Double { speed * 3.6 }
    var speedMinKmh: Double { speedMin * 3.6 }
    var speedMaxKmh: Double { speedMax * 3.6 }

    /// Vitesse en noeuds
    var speedKnots: Double { speed * 1.94384 }
    var speedMinKnots: Double { speedMin * 1.94384 }
    var speedMaxKnots: Double { speedMax * 1.94384 }

    /// Direction cardinale (N, NE, E, etc.)
    var directionCardinal: String {
        let directions = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let index = Int((direction + 22.5) / 45.0) % 8
        return directions[index]
    }

    /// Formatage de la vitesse selon l'unité choisie
    func formattedSpeed(unit: String = "knots") -> String {
        let (avg, min, max) = unit == "knots"
            ? (Int(speedKnots.rounded()), Int(speedMinKnots.rounded()), Int(speedMaxKnots.rounded()))
            : (Int(speedKmh.rounded()), Int(speedMinKmh.rounded()), Int(speedMaxKmh.rounded()))

        let unitLabel = unit == "knots" ? "kn" : "km/h"

        if min == max || (max - min) <= 2 {
            return "\(avg) \(unitLabel)"
        } else {
            return "\(avg) ±\(max - avg) \(unitLabel)"
        }
    }

    /// Fourchette formatée
    func formattedRange(unit: String = "knots") -> String {
        let (min, max) = unit == "knots"
            ? (Int(speedMinKnots.rounded()), Int(speedMaxKnots.rounded()))
            : (Int(speedMinKmh.rounded()), Int(speedMaxKmh.rounded()))

        let unitLabel = unit == "knots" ? "kn" : "km/h"
        return "\(min)-\(max) \(unitLabel)"
    }

    /// Niveau de confiance textuel
    var confidenceLevel: String {
        switch confidence {
        case 0.7...: return "Fiable"
        case 0.4..<0.7: return "Approximatif"
        default: return "Incertain"
        }
    }
}

// MARK: - Wind Estimator

/// Estimateur de vent basé sur les traces GPS
struct WindEstimator {

    // MARK: - Configuration

    /// Vitesses de trim par type de voile (km/h)
    static let trimSpeeds: [String: Double] = [
        "Soaring": 36,
        "Cross": 40,
        "Thermique": 38,
        "Speedflying": 50,
        "Acro": 42
    ]

    /// Vitesse de trim par défaut
    static let defaultTrimSpeed: Double = 37  // km/h

    /// Minimum de points GPS requis
    static let minimumTrackPoints = 12  // ~1 minute

    /// Minimum de directions couvertes (sur 8)
    static let minimumDirectionCoverage = 3

    // MARK: - Main Estimation

    /// Estime le vent à partir d'une trace GPS
    static func estimate(
        from track: [GPSTrackPoint],
        wingType: String? = nil,
        wingSize: Double? = nil,
        pilotWeight: Double? = nil
    ) -> WindEstimation? {

        // Vérifications préliminaires
        guard track.count >= minimumTrackPoints else {
            print("⚠️ Pas assez de points GPS (\(track.count) < \(minimumTrackPoints))")
            return nil
        }

        // Filtrer les points avec vitesse valide
        let validPoints = track.filter { point in
            guard let speed = point.speed else { return false }
            return speed > 0 && speed < 50  // 0-180 km/h
        }

        guard validPoints.count >= minimumTrackPoints else {
            print("⚠️ Pas assez de points avec vitesse valide")
            return nil
        }

        // Calculer les caps entre points consécutifs
        let segments = calculateSegments(from: validPoints)

        guard !segments.isEmpty else {
            print("⚠️ Impossible de calculer les segments")
            return nil
        }

        // Méthode principale : analyse de la variation de vitesse par direction
        return estimateFromSpeedVariation(
            segments: segments,
            wingType: wingType,
            wingSize: wingSize,
            pilotWeight: pilotWeight
        )
    }

    // MARK: - Speed Variation Method

    /// Structure pour stocker un segment de vol
    private struct FlightSegment {
        let heading: Double     // Cap en degrés (0-360)
        let groundSpeed: Double // Vitesse sol en m/s
        let duration: TimeInterval
    }

    /// Calcule les segments de vol avec cap et vitesse
    private static func calculateSegments(from points: [GPSTrackPoint]) -> [FlightSegment] {
        var segments: [FlightSegment] = []

        for i in 1..<points.count {
            let p1 = points[i-1]
            let p2 = points[i]

            // Calcul du cap
            let heading = calculateHeading(
                from: CLLocationCoordinate2D(latitude: p1.latitude, longitude: p1.longitude),
                to: CLLocationCoordinate2D(latitude: p2.latitude, longitude: p2.longitude)
            )

            // Utiliser la vitesse GPS du point actuel
            guard let speed = p2.speed, speed > 0.5 else { continue }  // Minimum 1.8 km/h

            let duration = p2.timestamp.timeIntervalSince(p1.timestamp)

            // Ignorer les segments trop longs (données manquantes)
            guard duration > 0 && duration < 30 else { continue }

            segments.append(FlightSegment(
                heading: heading,
                groundSpeed: speed,
                duration: duration
            ))
        }

        return segments
    }

    /// Calcule le cap entre deux coordonnées
    private static func calculateHeading(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let x = sin(dLon) * cos(lat2)
        let y = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        var heading = atan2(x, y) * 180 / .pi
        if heading < 0 { heading += 360 }

        return heading
    }

    /// Quantifie un cap en octant (0-7 pour N, NE, E, SE, S, SO, O, NO)
    private static func headingToOctant(_ heading: Double) -> Int {
        return Int((heading + 22.5) / 45.0) % 8
    }

    /// Estime le vent par analyse de la variation de vitesse selon la direction
    private static func estimateFromSpeedVariation(
        segments: [FlightSegment],
        wingType: String?,
        wingSize: Double?,
        pilotWeight: Double?
    ) -> WindEstimation? {

        // Grouper les vitesses par octant (8 directions)
        var speedsByDirection: [[Double]] = Array(repeating: [], count: 8)

        for segment in segments {
            let octant = headingToOctant(segment.heading)
            speedsByDirection[octant].append(segment.groundSpeed)
        }

        // Compter les directions avec suffisamment de données
        let directionsWithData = speedsByDirection.filter { $0.count >= 2 }.count

        guard directionsWithData >= minimumDirectionCoverage else {
            print("⚠️ Pas assez de directions couvertes (\(directionsWithData) < \(minimumDirectionCoverage))")
            return nil
        }

        // Calculer la vitesse médiane par direction
        var medianSpeeds: [Int: Double] = [:]
        for (octant, speeds) in speedsByDirection.enumerated() {
            guard speeds.count >= 2 else { continue }
            let sorted = speeds.sorted()
            let median = sorted.count % 2 == 0
                ? (sorted[sorted.count/2 - 1] + sorted[sorted.count/2]) / 2
                : sorted[sorted.count/2]
            medianSpeeds[octant] = median
        }

        guard medianSpeeds.count >= minimumDirectionCoverage else {
            return nil
        }

        // Trouver la direction avec vitesse max (vent arrière) et min (vent de face)
        let maxEntry = medianSpeeds.max(by: { $0.value < $1.value })!
        let minEntry = medianSpeeds.min(by: { $0.value < $1.value })!

        let maxSpeed = maxEntry.value
        let minSpeed = minEntry.value
        let tailWindDirection = Double(maxEntry.key) * 45  // Direction où on va le plus vite

        // Calculer la vitesse de trim ajustée en fonction du poids
        // La charge alaire affecte la vitesse de trim
        let baseTrimSpeed = (trimSpeeds[wingType ?? ""] ?? defaultTrimSpeed) / 3.6  // en m/s
        var adjustedTrimSpeed = baseTrimSpeed

        if let weight = pilotWeight, weight > 0, let size = wingSize, size > 0 {
            // Charge alaire = poids / surface
            let wingLoading = weight / size
            // Charge alaire de référence (typiquement 4.5-5.5 kg/m²)
            let referenceLoading = 5.0
            // Ajustement: +/- 3% par kg/m² d'écart
            let loadingDelta = wingLoading - referenceLoading
            let speedAdjustment = 1.0 + (loadingDelta * 0.03)
            adjustedTrimSpeed = baseTrimSpeed * speedAdjustment
            print("📊 Charge alaire: \(String(format: "%.1f", wingLoading)) kg/m², vitesse trim ajustée: \(String(format: "%.1f", adjustedTrimSpeed * 3.6)) km/h")
        }

        // Estimation du vent basée sur la différence de vitesses
        // En théorie: vitesse_sol = vitesse_air ± vitesse_vent
        // Donc: vent ≈ (vit_max - vit_min) / 2
        let windSpeed = (maxSpeed - minSpeed) / 2

        // Direction du vent = opposé de la direction de vitesse max
        // (on va vite quand le vent est dans le dos)
        var windDirection = tailWindDirection + 180
        if windDirection >= 360 { windDirection -= 360 }

        // Méthode alternative avec trim speed ajusté:
        // Si on connaît la vitesse air (trim), on peut affiner l'estimation
        // vitesse_air = (vit_max + vit_min) / 2 devrait être proche du trim
        let estimatedAirSpeed = (maxSpeed + minSpeed) / 2
        let trimDelta = abs(estimatedAirSpeed - adjustedTrimSpeed)

        print("📊 Vitesse air estimée: \(String(format: "%.1f", estimatedAirSpeed * 3.6)) km/h, trim attendu: \(String(format: "%.1f", adjustedTrimSpeed * 3.6)) km/h")

        // Calcul de l'incertitude basée sur la variance des mesures
        let allSpeeds = segments.map { $0.groundSpeed }
        let meanSpeed = allSpeeds.reduce(0, +) / Double(allSpeeds.count)
        let variance = allSpeeds.map { pow($0 - meanSpeed, 2) }.reduce(0, +) / Double(allSpeeds.count)
        let stdDev = sqrt(variance)

        // Fourchette basée sur l'écart-type et l'incertitude du trim
        let trimUncertainty = trimDelta * 0.3  // 30% de l'écart au trim
        let speedMin = max(0, windSpeed - stdDev * 0.5 - trimUncertainty)
        let speedMax = windSpeed + stdDev * 0.5 + trimUncertainty

        // Calcul du niveau de confiance
        var confidence = calculateConfidence(
            directionsWithData: directionsWithData,
            totalSegments: segments.count,
            speedDifference: maxSpeed - minSpeed,
            variance: variance
        )

        // Ajuster la confiance si la vitesse air estimée est loin du trim
        if trimDelta > 3 {  // Plus de 3 m/s d'écart
            confidence *= 0.8
        }

        // Bonus de confiance si on a le poids pilote (meilleur ajustement du trim)
        if pilotWeight != nil && wingSize != nil {
            confidence *= 1.1  // +10% de confiance
        } else if pilotWeight == nil {
            confidence *= 0.9
        }

        // Vérification de plausibilité
        let maxExpectedGroundSpeed = adjustedTrimSpeed + windSpeed + 5  // +5 m/s de marge

        if maxSpeed > maxExpectedGroundSpeed * 1.5 {
            confidence *= 0.7  // Réduire la confiance si les données semblent incohérentes
        }

        // Minimum de vent détectable (bruit GPS)
        if windSpeed < 1.0 {  // < 3.6 km/h
            return WindEstimation(
                speed: 0,
                speedMin: 0,
                speedMax: 2,
                direction: 0,
                confidence: 0.3,
                method: "speed_variation"
            )
        }

        return WindEstimation(
            speed: windSpeed,
            speedMin: speedMin,
            speedMax: speedMax,
            direction: windDirection,
            confidence: min(1.0, confidence),
            method: "speed_variation"
        )
    }

    /// Calcule le niveau de confiance
    private static func calculateConfidence(
        directionsWithData: Int,
        totalSegments: Int,
        speedDifference: Double,
        variance: Double
    ) -> Double {

        var confidence = 0.5  // Base

        // Bonus pour couverture des directions (max +0.3)
        let coverageBonus = Double(directionsWithData - minimumDirectionCoverage) * 0.1
        confidence += min(0.3, coverageBonus)

        // Bonus pour nombre de segments (max +0.2)
        let segmentBonus = Double(totalSegments - minimumTrackPoints) / 100.0
        confidence += min(0.2, segmentBonus)

        // Malus si la différence de vitesse est faible (vent faible = moins précis)
        if speedDifference < 3 {  // < 10 km/h de différence
            confidence -= 0.2
        }

        // Malus si la variance est très élevée (données bruitées)
        if variance > 25 {  // écart-type > 5 m/s
            confidence -= 0.15
        }

        return max(0.1, min(1.0, confidence))
    }

    // MARK: - Utility Functions

    /// Convertit m/s en noeuds
    static func msToKnots(_ ms: Double) -> Double {
        return ms * 1.94384
    }

    /// Convertit m/s en km/h
    static func msToKmh(_ ms: Double) -> Double {
        return ms * 3.6
    }

    /// Convertit noeuds en m/s
    static func knotsToMs(_ knots: Double) -> Double {
        return knots / 1.94384
    }

    /// Convertit km/h en m/s
    static func kmhToMs(_ kmh: Double) -> Double {
        return kmh / 3.6
    }
}

// MARK: - Flight Extension

extension Flight {
    /// Calcule et stocke l'estimation du vent pour ce vol
    func calculateWindEstimation() {
        guard let track = gpsTrack, !track.isEmpty else {
            print("⚠️ Pas de trace GPS pour ce vol")
            return
        }

        print("🌬️ Calcul du vent avec \(track.count) points GPS")

        let wingType = wing?.type
        // Parser la taille de la voile (peut être "18", "18m²", etc.)
        var wingSize: Double? = nil
        if let sizeStr = wing?.size {
            // Extraire les chiffres de la chaîne
            let digits = sizeStr.filter { $0.isNumber || $0 == "." || $0 == "," }
            wingSize = Double(digits.replacingOccurrences(of: ",", with: "."))
        }
        let pilotWeight = UserDefaults.standard.double(forKey: "pilotWeight")

        print("📊 Paramètres: type=\(wingType ?? "nil"), taille=\(wingSize ?? 0), poids=\(pilotWeight)")

        if let estimation = WindEstimator.estimate(
            from: track,
            wingType: wingType,
            wingSize: wingSize,
            pilotWeight: pilotWeight > 0 ? pilotWeight : nil
        ) {
            print("✅ Estimation: \(estimation.speed) m/s, direction \(estimation.direction)°, confiance \(estimation.confidence)")
            windSpeed = estimation.speed
            windSpeedMin = estimation.speedMin
            windSpeedMax = estimation.speedMax
            windDirection = estimation.direction
            windConfidence = estimation.confidence
        } else {
            print("❌ Impossible d'estimer le vent")
        }
    }

    /// Retourne l'estimation du vent formatée
    func formattedWindEstimation(unit: String? = nil) -> String? {
        guard let speed = windSpeed, speed > 0 else { return nil }

        let windUnit = unit ?? UserDefaults.standard.string(forKey: "windUnit") ?? "knots"

        let speedValue: Int
        let unitLabel: String

        if windUnit == "knots" {
            speedValue = Int((speed * 1.94384).rounded())
            unitLabel = "kn"
        } else {
            speedValue = Int((speed * 3.6).rounded())
            unitLabel = "km/h"
        }

        if let dir = windDirection {
            let directions = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
            let index = Int((dir + 22.5) / 45.0) % 8
            return "\(speedValue) \(unitLabel) \(directions[index])"
        }

        return "\(speedValue) \(unitLabel)"
    }

    /// Retourne la fourchette de vent formatée
    func formattedWindRange(unit: String? = nil) -> String? {
        guard let min = windSpeedMin, let max = windSpeedMax else { return nil }

        let windUnit = unit ?? UserDefaults.standard.string(forKey: "windUnit") ?? "knots"

        let minValue: Int
        let maxValue: Int
        let unitLabel: String

        if windUnit == "knots" {
            minValue = Int((min * 1.94384).rounded())
            maxValue = Int((max * 1.94384).rounded())
            unitLabel = "kn"
        } else {
            minValue = Int((min * 3.6).rounded())
            maxValue = Int((max * 3.6).rounded())
            unitLabel = "km/h"
        }

        return "\(minValue)-\(maxValue) \(unitLabel)"
    }
}
