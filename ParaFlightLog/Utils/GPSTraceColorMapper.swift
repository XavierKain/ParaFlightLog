//
//  GPSTraceColorMapper.swift
//  ParaFlightLog
//
//  Utilitaire pour générer des segments GPS colorés par vitesse
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
class GPSTraceColorMapper {

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

    /// Map vitesse → couleur (gradient discret)
    static func colorForSpeed(_ speedKmh: Double) -> Color {
        switch speedKmh {
        case ..<10:
            return .blue      // Très lent (thermique, atterrissage)
        case 10..<25:
            return .green     // Lent (vol normal)
        case 25..<40:
            return .yellow    // Moyen (transition)
        case 40..<60:
            return .orange    // Rapide (accélération)
        default:
            return .red       // Très rapide (piqué, descente rapide)
        }
    }

    /// Variante avec gradient continu (optionnel)
    static func colorForSpeedGradient(_ speedKmh: Double) -> Color {
        // Mapping: 0 km/h = bleu, 60+ km/h = rouge
        let normalized = min(max(speedKmh / 60.0, 0), 1)

        // Interpolation HSB (Hue-Saturation-Brightness)
        // Bleu (240°) → Vert (120°) → Jaune (60°) → Rouge (0°)
        let hue = (1.0 - normalized) * 240.0 / 360.0

        return Color(hue: hue, saturation: 0.8, brightness: 0.9)
    }

    /// Obtient la légende des couleurs pour affichage
    static func getSpeedLegend() -> [(speed: String, color: Color)] {
        return [
            ("<10 km/h", .blue),
            ("10-25 km/h", .green),
            ("25-40 km/h", .yellow),
            ("40-60 km/h", .orange),
            ("60+ km/h", .red)
        ]
    }
}
