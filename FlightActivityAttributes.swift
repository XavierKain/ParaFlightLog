//
//  FlightActivityAttributes.swift
//  SoarX
//
//  Données partagées entre l'app iOS et l'extension Live Activity.
//  (Compilé dans le target iOS ET dans le target SoarXLiveActivity.)
//

import Foundation
import ActivityKit

/// Attributs d'une Live Activity « vol en cours » (écran verrouillé + Dynamic Island).
struct FlightActivityAttributes: ActivityAttributes {
    /// Données qui évoluent pendant le vol
    public struct ContentState: Codable, Hashable {
        /// Heure de décollage (le chrono se met à jour tout seul à partir d'elle)
        var startDate: Date
        /// Altitude courante (m), si disponible
        var altitude: Double?
        /// Vitesse verticale courante (m/s), si disponible
        var verticalSpeed: Double?
        /// Nom du spot, si connu
        var spotName: String?
    }

    /// Données fixes pour toute la durée du vol
    var wingName: String
    var flightType: String?
}
