//
//  GPSTraceColorMapper.swift
//  ParaFlightLog
//
//  Utilitaire pour générer des segments GPS colorés par vitesse
//  (horizontale ou verticale) — gradient continu pour une visualisation fluide
//  Target: iOS only
//

import Foundation
import SwiftUI
import CoreLocation

/// Segment de trace GPS avec couleur basée sur la vitesse
/// En mode vitesse horizontale : `speed` en km/h
/// En mode vitesse verticale (vario) : `speed` contient la Vz en m/s
struct SpeedSegment: Identifiable {
    let id = UUID()
    let startPoint: GPSTrackPoint
    let endPoint: GPSTrackPoint
    let speed: Double // km/h (mode vitesse) ou m/s (mode vario)
    let color: Color
}

/// Statistiques verticales d'un vol calculées depuis la trace GPS
struct VerticalStats {
    /// Gain d'altitude cumulé (m) — somme des montées au-dessus du seuil de bruit
    let totalGain: Double
    /// Meilleure ascendance (m/s, ≥ 0)
    let maxClimbRate: Double
    /// Plus forte descente (m/s, ≤ 0)
    let maxSinkRate: Double
    /// Altitude maximale de la trace (m)
    let maxAltitude: Double?
    /// Altitude minimale de la trace (m)
    let minAltitude: Double?
}

/// Mapper de couleurs pour traces GPS basées sur la vitesse
/// Utilise un gradient continu: Bleu (lent) → Cyan → Vert → Jaune → Orange → Rouge (rapide)
class GPSTraceColorMapper {

    /// Vitesse minimale pour le gradient (km/h)
    static let minSpeed: Double = 0
    /// Vitesse maximale pour le gradient (km/h)
    static let maxSpeed: Double = 60

    /// Calcule les vitesses et assigne les couleurs pour chaque segment
    static func generateColoredSegments(points: [GPSTrackPoint]) -> [SpeedSegment] {
        guard points.count >= 2 else { return [] }

        var segments: [SpeedSegment] = []

        for i in 1..<points.count {
            let prev = points[i-1]
            let curr = points[i]

            // Calculer la distance entre les deux points
            let distance = GPSDistanceCalculator.haversineDistance(
                lat1: prev.latitude, lon1: prev.longitude,
                lat2: curr.latitude, lon2: curr.longitude
            )

            let timeInterval = curr.timestamp.timeIntervalSince(prev.timestamp)

            guard timeInterval > 0 else { continue }

            let speedMps = distance / timeInterval
            let speedKmh = speedMps * 3.6

            let color = colorForSpeed(speedKmh)

            segments.append(SpeedSegment(
                startPoint: prev,
                endPoint: curr,
                speed: speedKmh,
                color: color
            ))
        }

        return segments
    }

    /// Map vitesse → couleur avec gradient continu
    /// 0 km/h = Bleu → 30 km/h = Vert/Jaune → 60+ km/h = Rouge
    static func colorForSpeed(_ speedKmh: Double) -> Color {
        // Normaliser la vitesse entre 0 et 1
        let normalized = min(max(speedKmh / maxSpeed, 0), 1)

        // Utiliser l'espace HSB pour un gradient fluide
        // Hue: 240° (bleu) → 180° (cyan) → 120° (vert) → 60° (jaune) → 30° (orange) → 0° (rouge)
        // On inverse: 0 = bleu (hue ~0.66), 1 = rouge (hue = 0)
        let hue = (1.0 - normalized) * 0.66  // 0.66 = 240°/360° (bleu)

        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }

    /// Obtient les couleurs du gradient pour la légende
    static func getGradientColors() -> [Color] {
        return [
            Color(hue: 0.66, saturation: 0.85, brightness: 0.95),  // Bleu (0 km/h)
            Color(hue: 0.50, saturation: 0.85, brightness: 0.95),  // Cyan
            Color(hue: 0.33, saturation: 0.85, brightness: 0.95),  // Vert
            Color(hue: 0.16, saturation: 0.85, brightness: 0.95),  // Jaune/Orange
            Color(hue: 0.00, saturation: 0.85, brightness: 0.95)   // Rouge (60+ km/h)
        ]
    }

    // MARK: - Vitesse verticale (Vz / vario)

    /// Vitesse verticale minimale du gradient vario (m/s)
    static let minVerticalSpeed: Double = -4
    /// Vitesse verticale maximale du gradient vario (m/s)
    static let maxVerticalSpeed: Double = 4
    /// Seuil sous lequel la Vz est considérée comme du bruit GPS (m/s)
    static let verticalNoiseThreshold: Double = 0.3
    /// Zone neutre autour de zéro pour la coloration vario (m/s)
    private static let varioDeadband: Double = 0.2
    /// Couleur neutre pour les segments sans altitude exploitable
    static let neutralVerticalColor = Color(white: 0.75)

    /// Calcule la vitesse verticale lissée (m/s) pour chaque point de la trace.
    /// Lissage sur une fenêtre glissante d'environ 5 s (au minimum 3 points).
    /// Retourne `nil` pour les points sans altitude exploitable dans la fenêtre.
    static func smoothedVerticalSpeeds(points: [GPSTrackPoint]) -> [Double?] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: nil, count: n) }

        let halfWindow: TimeInterval = 2.5  // fenêtre totale ≈ 5 s
        var result: [Double?] = Array(repeating: nil, count: n)

        for i in 0..<n {
            let t = points[i].timestamp

            // Bornes temporelles de la fenêtre centrée sur le point i
            var lo = i
            while lo > 0 && t.timeIntervalSince(points[lo - 1].timestamp) <= halfWindow {
                lo -= 1
            }
            var hi = i
            while hi < n - 1 && points[hi + 1].timestamp.timeIntervalSince(t) <= halfWindow {
                hi += 1
            }

            // Garantir au moins 3 points dans la fenêtre si possible
            while hi - lo < 2 {
                if lo > 0 {
                    lo -= 1
                } else if hi < n - 1 {
                    hi += 1
                } else {
                    break
                }
            }

            // Premier et dernier point de la fenêtre avec altitude valide
            guard let firstIdx = (lo...hi).first(where: { points[$0].altitude != nil }),
                  let lastIdx = (lo...hi).last(where: { points[$0].altitude != nil }),
                  firstIdx < lastIdx,
                  let altFirst = points[firstIdx].altitude,
                  let altLast = points[lastIdx].altitude else { continue }

            let dt = points[lastIdx].timestamp.timeIntervalSince(points[firstIdx].timestamp)
            guard dt > 0 else { continue }

            result[i] = (altLast - altFirst) / dt
        }

        return result
    }

    /// Génère des segments colorés par vitesse verticale (mode vario / « montée »)
    /// `speed` du segment contient la Vz lissée en m/s.
    /// Les segments sans altitude exploitable reçoivent une couleur neutre.
    static func generateVerticalSpeedSegments(points: [GPSTrackPoint]) -> [SpeedSegment] {
        guard points.count >= 2 else { return [] }

        let verticalSpeeds = smoothedVerticalSpeeds(points: points)
        var segments: [SpeedSegment] = []

        for i in 1..<points.count {
            let prev = points[i-1]
            let curr = points[i]

            guard curr.timestamp.timeIntervalSince(prev.timestamp) > 0 else { continue }

            // Vz du segment = moyenne des Vz des deux extrémités (si disponibles)
            let vz: Double?
            switch (verticalSpeeds[i-1], verticalSpeeds[i]) {
            case let (a?, b?): vz = (a + b) / 2
            case let (a?, nil): vz = a
            case let (nil, b?): vz = b
            default: vz = nil
            }

            // Segment neutre si pas d'altitude exploitable
            let color = vz.map { colorForVerticalSpeed($0) } ?? neutralVerticalColor

            segments.append(SpeedSegment(
                startPoint: prev,
                endPoint: curr,
                speed: vz ?? 0,
                color: color
            ))
        }

        return segments
    }

    /// Map Vz (m/s) → couleur selon la convention vario :
    /// montée = dégradé jaune → rouge selon la force,
    /// proche de 0 = gris/blanc,
    /// descente = dégradé bleu clair → bleu foncé/violet pour les fortes descentes.
    /// Plage utile clampée à -4…+4 m/s.
    static func colorForVerticalSpeed(_ vz: Double) -> Color {
        let clamped = min(max(vz, minVerticalSpeed), maxVerticalSpeed)

        // Zone neutre autour de zéro : gris/blanc
        if abs(clamped) < varioDeadband {
            return Color(hue: 0, saturation: 0, brightness: 0.88)
        }

        if clamped > 0 {
            // Montée : jaune (hue 0.16) → rouge (hue 0.0)
            let t = (clamped - varioDeadband) / (maxVerticalSpeed - varioDeadband)
            let hue = 0.16 * (1.0 - t)
            return Color(hue: hue, saturation: 0.9, brightness: 0.95)
        } else {
            // Descente : bleu clair (hue ~0.52) → bleu foncé/violet (hue ~0.75)
            let t = (-clamped - varioDeadband) / (maxVerticalSpeed - varioDeadband)
            let hue = 0.52 + 0.23 * t
            let brightness = 0.95 - 0.35 * t
            return Color(hue: hue, saturation: 0.85, brightness: brightness)
        }
    }

    /// Couleurs du gradient vario pour la légende (de -4 à +4 m/s)
    static func getVarioGradientColors() -> [Color] {
        stride(from: minVerticalSpeed, through: maxVerticalSpeed, by: 0.5)
            .map { colorForVerticalSpeed($0) }
    }

    /// Calcule les statistiques verticales d'une trace GPS.
    /// Gain cumulé = intégration des Vz lissées positives au-dessus du seuil
    /// de bruit (|Vz| < 0,3 m/s ignoré pour filtrer le bruit GPS).
    /// Retourne `nil` si la trace ne contient pas assez de points avec altitude.
    static func verticalStats(points: [GPSTrackPoint]) -> VerticalStats? {
        let altitudes = points.compactMap { $0.altitude }
        guard points.count >= 2, altitudes.count >= 2 else { return nil }

        let verticalSpeeds = smoothedVerticalSpeeds(points: points)

        var totalGain: Double = 0
        var maxClimb: Double = 0
        var maxSink: Double = 0

        for i in 1..<points.count {
            guard let vz = verticalSpeeds[i] else { continue }

            maxClimb = max(maxClimb, vz)
            maxSink = min(maxSink, vz)

            // Gain cumulé : somme des deltas positifs sur la Vz lissée
            if vz >= verticalNoiseThreshold {
                let dt = points[i].timestamp.timeIntervalSince(points[i-1].timestamp)
                if dt > 0 {
                    totalGain += vz * dt
                }
            }
        }

        return VerticalStats(
            totalGain: totalGain,
            maxClimbRate: maxClimb,
            maxSinkRate: maxSink,
            maxAltitude: altitudes.max(),
            minAltitude: altitudes.min()
        )
    }
}
