//
//  Color+String.swift
//  ParaFlightLog
//
//  Extensions pour les couleurs SwiftUI
//  - Conversion de noms de couleurs (français/anglais)
//  - Initialisation depuis code hex
//  Target: iOS + Watch (shared)
//

import SwiftUI

// MARK: - String to Color

extension String {
    /// Convertit un nom de couleur (français ou anglais) en Color SwiftUI
    func toColor() -> Color {
        switch self.lowercased() {
        case "rouge", "red":
            return .red
        case "bleu", "blue":
            return .blue
        case "vert", "green":
            return .green
        case "jaune", "yellow":
            return .yellow
        case "orange":
            return .orange
        case "violet", "purple":
            return .purple
        case "noir", "black":
            return .black
        case "pétrole", "teal":
            return .teal
        case "blanc", "white":
            return .white
        default:
            return .gray
        }
    }
}

// MARK: - Color from Hex
// Note: Color(hex:) is now provided natively by SwiftUI in iOS 26+
// Our custom implementation has been removed to avoid conflicts
