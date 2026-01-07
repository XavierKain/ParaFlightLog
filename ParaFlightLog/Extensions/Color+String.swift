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

// MARK: - Color from Hex String

extension Color {
    /// Crée une couleur depuis un code hex string (ex: "#FF3B30" ou "FF3B30")
    /// Retourne nil si le format est invalide
    static func fromHex(_ hex: String) -> Color? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6,
              let hexNumber = UInt64(hexSanitized, radix: 16) else {
            return nil
        }

        let r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
        let g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
        let b = Double(hexNumber & 0x0000FF) / 255.0

        return Color(red: r, green: g, blue: b)
    }
}
