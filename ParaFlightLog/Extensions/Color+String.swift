//
//  Color+String.swift
//  ParaFlightLog
//
//  Extension pour convertir les noms de couleurs en Color SwiftUI
//  Supporte les noms français et anglais
//  Target: iOS + Watch (shared)
//

import SwiftUI

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
