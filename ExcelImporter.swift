//
//  ExcelImporter.swift
//  ParaFlightLog
//
//  Service d'import de données depuis Excel
//  Parse les fichiers .xlsx et crée les Wings et Flights correspondants
//  Target: iOS only
//

import Foundation
import UniformTypeIdentifiers
import CoreLocation

struct ExcelImporter {

    /// Parse un fichier Excel et retourne les données structurées
    /// Format attendu: Date, Voile, Spot, Durée, Vent moyen (kn), Notes
    static func parseExcelFile(at url: URL) throws -> ExcelFlightData {
        // Pour l'instant, on va créer une méthode qui lit le CSV exporté depuis Excel
        // Swift n'a pas de parser XLSX natif, on va donc demander à l'utilisateur
        // d'exporter en CSV depuis Excel ou utiliser une librairie tierce

        guard url.startAccessingSecurityScopedResource() else {
            throw ExcelImportError.fileAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ExcelImportError.invalidEncoding
        }

        return try parseCSVContent(content)
    }

    /// Parse le contenu CSV
    private static func parseCSVContent(_ content: String) throws -> ExcelFlightData {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        guard lines.count > 1 else {
            throw ExcelImportError.emptyFile
        }

        // Ignorer la première ligne (en-têtes)
        let dataLines = Array(lines.dropFirst())

        var flights: [ExcelFlightRow] = []
        let dateFormatter = DateFormatter()
        // Essayer plusieurs formats de date
        let dateFormats = ["dd/MM/yyyy", "d/MM/yyyy", "dd/M/yyyy", "d/M/yyyy",
                          "yyyy-MM-dd", "dd-MM-yyyy", "yyyy-MM-dd HH:mm:ss"]

        for (index, line) in dataLines.enumerated() {
            // Parser CSV en tenant compte des virgules entre guillemets
            let columns = parseCSVLine(line)

            guard columns.count >= 4 else {
                print("⚠️ Ligne \(index + 2) ignorée: nombre de colonnes insuffisant")
                continue
            }

            // Colonnes: Date, Voile, Spot, Durée, Vent moyen (kn), Notes
            let dateString = columns[0].trimmingCharacters(in: .whitespaces)
            let wingName = columns[1].trimmingCharacters(in: .whitespaces)
            let spotName = columns[2].trimmingCharacters(in: .whitespaces)
            let durationString = columns[3].trimmingCharacters(in: .whitespaces)
            let windSpeed = columns.count > 4 ? columns[4].trimmingCharacters(in: .whitespaces) : nil
            let notes = columns.count > 5 ? columns[5].trimmingCharacters(in: .whitespaces) : nil

            // Parser la date
            var date: Date?
            for format in dateFormats {
                dateFormatter.dateFormat = format
                if let parsedDate = dateFormatter.date(from: dateString) {
                    date = parsedDate
                    break
                }
            }

            guard let flightDate = date else {
                print("⚠️ Ligne \(index + 2): date invalide '\(dateString)'")
                continue
            }

            // Parser la durée (format: "1h30", "45min", "2h", etc.)
            guard let duration = parseDuration(durationString) else {
                print("⚠️ Ligne \(index + 2): durée invalide '\(durationString)'")
                continue
            }

            let flight = ExcelFlightRow(
                date: flightDate,
                wingName: wingName,
                spotName: spotName,
                durationSeconds: duration,
                windSpeed: windSpeed,
                notes: notes
            )

            flights.append(flight)
        }

        if flights.isEmpty {
            throw ExcelImportError.noValidData
        }

        return ExcelFlightData(flights: flights)
    }

    /// Parse une ligne CSV en tenant compte des guillemets
    private static func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var currentColumn = ""
        var insideQuotes = false

        for char in line {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                columns.append(currentColumn)
                currentColumn = ""
            } else {
                currentColumn.append(char)
            }
        }
        columns.append(currentColumn)

        return columns.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    /// Parse une durée au format "1h30", "45min", "2h", "5:00:00", etc.
    private static func parseDuration(_ duration: String) -> Int? {
        let cleaned = duration.lowercased().trimmingCharacters(in: .whitespaces)

        // Format "H:MM:SS" ou "HH:MM:SS" (Excel export format)
        if cleaned.contains(":") {
            let components = cleaned.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 3 {
                // Format H:MM:SS
                guard let hours = Int(components[0]),
                      let minutes = Int(components[1]),
                      let seconds = Int(components[2]) else {
                    print("⚠️ Failed to parse duration components: \(components)")
                    return nil
                }
                return hours * 3600 + minutes * 60 + seconds
            } else if components.count == 2 {
                // Format H:MM (sans secondes)
                guard let hours = Int(components[0]),
                      let minutes = Int(components[1]) else {
                    print("⚠️ Failed to parse duration components: \(components)")
                    return nil
                }
                return hours * 3600 + minutes * 60
            }
        }

        // Format "1h30" ou "1h 30"
        if let hIndex = cleaned.firstIndex(of: "h") {
            let hoursString = String(cleaned[..<hIndex])
            guard let hours = Int(hoursString) else { return nil }

            let afterH = cleaned[cleaned.index(after: hIndex)...]
            let minutesString = afterH.filter { $0.isNumber }
            let minutes = Int(minutesString) ?? 0

            return hours * 3600 + minutes * 60
        }

        // Format "45min" ou "45 min"
        if cleaned.contains("min") {
            let minutesString = cleaned.filter { $0.isNumber }
            guard let minutes = Int(minutesString) else { return nil }
            return minutes * 60
        }

        // Format nombre seul (considéré comme minutes)
        if let minutes = Int(cleaned) {
            return minutes * 60
        }

        print("⚠️ Could not parse duration: '\(duration)'")
        return nil
    }

    /// Importe les données dans la base de données
    static func importToDatabase(data: ExcelFlightData, dataController: DataController) throws -> ImportResult {
        var createdWings: Set<String> = []
        var importedFlights = 0
        var errors: [String] = []

        // Grouper les vols par voile
        let flightsByWing = Dictionary(grouping: data.flights, by: { $0.wingName })

        for (wingName, flights) in flightsByWing {
            // Vérifier si la voile existe déjà
            let existingWings = dataController.fetchWings()
            var wing = existingWings.first { $0.name == wingName }

            // Créer la voile si elle n'existe pas
            if wing == nil {
                dataController.addWing(name: wingName)
                let newWings = dataController.fetchWings()
                wing = newWings.first { $0.name == wingName }
                createdWings.insert(wingName)
            }

            guard let targetWing = wing else {
                errors.append("Impossible de créer/trouver la voile: \(wingName)")
                continue
            }

            // Créer les vols
            for flight in flights {
                let endDate = flight.date.addingTimeInterval(TimeInterval(flight.durationSeconds))

                dataController.addFlight(
                    wing: targetWing,
                    startDate: flight.date,
                    endDate: endDate,
                    durationSeconds: flight.durationSeconds,
                    location: nil, // Pas de coordonnées GPS dans Excel
                    spotName: flight.spotName,
                    flightType: nil,
                    notes: [flight.windSpeed, flight.notes]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " | ")
                )

                importedFlights += 1
            }
        }

        return ImportResult(
            wingsCreated: createdWings.count,
            flightsImported: importedFlights,
            errors: errors
        )
    }
}

// MARK: - Data Models

struct ExcelFlightData {
    let flights: [ExcelFlightRow]
}

struct ExcelFlightRow {
    let date: Date
    let wingName: String
    let spotName: String
    let durationSeconds: Int
    let windSpeed: String?
    let notes: String?
}

struct ImportResult {
    let wingsCreated: Int
    let flightsImported: Int
    let errors: [String]

    var summary: String {
        var result = "✅ Import terminé:\n"
        result += "- \(wingsCreated) voile\(wingsCreated > 1 ? "s" : "") créée\(wingsCreated > 1 ? "s" : "")\n"
        result += "- \(flightsImported) vol\(flightsImported > 1 ? "s" : "") importé\(flightsImported > 1 ? "s" : "")"

        if !errors.isEmpty {
            result += "\n\n⚠️ Erreurs:\n"
            result += errors.joined(separator: "\n")
        }

        return result
    }
}

// MARK: - Errors

enum ExcelImportError: LocalizedError {
    case fileAccessDenied
    case invalidEncoding
    case emptyFile
    case noValidData
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied:
            return "Impossible d'accéder au fichier"
        case .invalidEncoding:
            return "Encodage du fichier invalide"
        case .emptyFile:
            return "Le fichier est vide"
        case .noValidData:
            return "Aucune donnée valide trouvée"
        case .invalidFormat:
            return "Format de fichier invalide"
        }
    }
}
