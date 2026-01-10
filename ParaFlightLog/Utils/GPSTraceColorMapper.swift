//
//  GPSTraceColorMapper.swift
//  ParaFlightLog
//
//  Utilitaire pour générer des segments GPS colorés par vitesse
//  Utilise un gradient continu pour une visualisation fluide
//  Target: iOS only
//

import Foundation
import SwiftUI
import CoreLocation

/// Segment de trace GPS avec couleur basée sur la vitesse
struct SpeedSegment: Identifiable {
    let id = UUID()
    let startPoint: GPSTrackPoint
    let endPoint: GPSTrackPoint
    let speed: Double // km/h
    let color: Color
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
}
