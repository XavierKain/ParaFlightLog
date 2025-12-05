//
//  ZipBackup.swift
//  ParaFlightLog
//
//  Gestion de l'export et import de backups complets au format ZIP
//  Contient: wings.csv, flights.csv, images/, metadata.json
//  NOTE: Utilise FileManager pour créer un dossier au lieu d'un vrai ZIP
//        pour compatibilité iOS (Process n'est pas disponible)
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

struct ZipBackup {

    // MARK: - Metadata Structure

    struct BackupMetadata: Codable {
        let version: String
        let appVersion: String
        let exportDate: Date
        let wingsCount: Int
        let flightsCount: Int
        let imagesCount: Int

        static func create(wingsCount: Int, flightsCount: Int, imagesCount: Int) -> BackupMetadata {
            BackupMetadata(
                version: "1.0",
                appVersion: "1.0.0", // TODO: Get from bundle
                exportDate: Date(),
                wingsCount: wingsCount,
                flightsCount: flightsCount,
                imagesCount: imagesCount
            )
        }
    }

    // MARK: - Export to Folder Bundle (iOS-compatible)

    /// Exporte toutes les données dans un dossier bundle .paraflightlog
    /// - Parameters:
    ///   - wings: Liste des voiles à exporter
    ///   - flights: Liste des vols à exporter
    ///   - completion: Callback avec l'URL du dossier bundle créé (ou erreur)
    static func exportToZip(wings: [Wing], flights: [Flight], completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Créer le dossier bundle .paraflightlog directement
                let bundleName = "ParaFlightLog_Backup_\(formatDateForFilename(Date())).paraflightlog"
                let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(bundleName)

                // Supprimer si existe déjà
                try? FileManager.default.removeItem(at: bundleURL)

                // Créer le dossier bundle
                try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

                // 1. Créer le dossier images/
                let imagesDir = bundleURL.appendingPathComponent("images")
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

                // 2. Exporter les voiles en CSV et sauvegarder les images
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "dd/MM/yyyy HH:mm"

                var wingsCSV = "ID,Nom,Taille,Type,Couleur,Archivé,Date de création,Ordre d'affichage,Photo\n"
                var imagesCount = 0

                for wing in wings.sorted(by: { $0.createdAt < $1.createdAt }) {
                    let id = wing.id.uuidString
                    let name = escapeCSV(wing.name)
                    let size = escapeCSV(wing.size ?? "")
                    let type = escapeCSV(wing.type ?? "")
                    let color = escapeCSV(wing.color ?? "")
                    let archived = wing.isArchived ? "Oui" : "Non"
                    let created = dateFormatter.string(from: wing.createdAt)
                    let displayOrder = "\(wing.displayOrder)"

                    // Sauvegarder l'image si elle existe
                    var photoFilename = ""
                    if let photoData = wing.photoData {
                        photoFilename = "\(id).jpg"
                        let photoURL = imagesDir.appendingPathComponent(photoFilename)
                        try photoData.write(to: photoURL)
                        imagesCount += 1
                    }

                    wingsCSV += "\(id),\(name),\(size),\(type),\(color),\(archived),\(created),\(displayOrder),\(photoFilename)\n"
                }

                // 3. Exporter les vols en CSV
                var flightsCSV = "ID,Date début,Date fin,Durée (sec),Voile ID,Voile Nom,Spot,Latitude,Longitude,Type,Notes\n"

                for flight in flights.sorted(by: { $0.startDate < $1.startDate }) {
                    let id = flight.id.uuidString
                    let startDate = dateFormatter.string(from: flight.startDate)
                    let endDate = dateFormatter.string(from: flight.endDate)
                    let duration = "\(flight.durationSeconds)"
                    let wingId = flight.wing?.id.uuidString ?? ""
                    let wingName = escapeCSV(flight.wing?.name ?? "Inconnu")
                    let spotName = escapeCSV(flight.spotName ?? "")
                    let lat = flight.latitude.map { String($0) } ?? ""
                    let lon = flight.longitude.map { String($0) } ?? ""
                    let flightType = escapeCSV(flight.flightType ?? "")
                    let notes = escapeCSV(flight.notes ?? "")

                    flightsCSV += "\(id),\(startDate),\(endDate),\(duration),\(wingId),\(wingName),\(spotName),\(lat),\(lon),\(flightType),\"\(notes)\"\n"
                }

                // 4. Écrire les CSVs
                let wingsURL = bundleURL.appendingPathComponent("wings.csv")
                let flightsURL = bundleURL.appendingPathComponent("flights.csv")
                try wingsCSV.write(to: wingsURL, atomically: true, encoding: .utf8)
                try flightsCSV.write(to: flightsURL, atomically: true, encoding: .utf8)

                // 5. Créer metadata.json
                let metadata = BackupMetadata.create(
                    wingsCount: wings.count,
                    flightsCount: flights.count,
                    imagesCount: imagesCount
                )
                let metadataData = try JSONEncoder().encode(metadata)
                let metadataURL = bundleURL.appendingPathComponent("metadata.json")
                try metadataData.write(to: metadataURL)

                // 6. Retourner l'URL du dossier bundle (pas besoin d'archiver)
                DispatchQueue.main.async {
                    completion(.success(bundleURL))
                }

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Import from Folder Bundle

    /// Importe les données depuis un dossier bundle .paraflightlog
    /// - Parameters:
    ///   - zipURL: URL du dossier bundle .paraflightlog à importer
    ///   - dataController: DataController pour insérer les données
    ///   - mergeMode: Si true, merge avec données existantes. Si false, remplace tout.
    ///   - completion: Callback avec le résultat (nombre d'éléments importés ou erreur)
    static func importFromZip(
        zipURL: URL,
        dataController: DataController,
        mergeMode: Bool = true,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Obtenir l'accès sécurisé au fichier
                let gotAccess = zipURL.startAccessingSecurityScopedResource()
                defer {
                    if gotAccess {
                        zipURL.stopAccessingSecurityScopedResource()
                    }
                }

                // Le dossier bundle est directement accessible
                let extractedDir = zipURL

                // 1. Lire metadata.json pour validation
                let metadataURL = extractedDir.appendingPathComponent("metadata.json")
                guard FileManager.default.fileExists(atPath: metadataURL.path) else {
                    throw NSError(domain: "ZipBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid backup: metadata.json not found"])
                }

                let metadataData = try Data(contentsOf: metadataURL)
                let metadata = try JSONDecoder().decode(BackupMetadata.self, from: metadataData)
                print("📦 Importing backup from \(metadata.exportDate): \(metadata.wingsCount) wings, \(metadata.flightsCount) flights")

                // 2. Parser wings.csv
                let wingsURL = extractedDir.appendingPathComponent("wings.csv")
                guard FileManager.default.fileExists(atPath: wingsURL.path) else {
                    throw NSError(domain: "ZipBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "wings.csv not found"])
                }

                let wingsCSV = try String(contentsOf: wingsURL, encoding: .utf8)
                let wingsRows = wingsCSV.components(separatedBy: "\n").dropFirst() // Skip header

                var importedWings: [UUID: Wing] = [:]
                var wingsCount = 0

                for row in wingsRows {
                    guard !row.isEmpty else { continue }
                    let cols = parseCSVRow(row)
                    guard cols.count >= 8 else { continue }

                    guard let wingId = UUID(uuidString: cols[0]) else { continue }

                    let wing = Wing(
                        name: cols[1],
                        size: cols[2].isEmpty ? nil : cols[2],
                        type: cols[3].isEmpty ? nil : cols[3],
                        color: cols[4].isEmpty ? nil : cols[4]
                    )
                    wing.id = wingId
                    wing.isArchived = cols[5] == "Oui"
                    if let displayOrder = Int(cols[7]) {
                        wing.displayOrder = displayOrder
                    }

                    // Charger l'image si elle existe
                    if !cols[8].isEmpty {
                        let imagePath = extractedDir.appendingPathComponent("images").appendingPathComponent(cols[8])
                        if FileManager.default.fileExists(atPath: imagePath.path) {
                            wing.photoData = try? Data(contentsOf: imagePath)
                        }
                    }

                    importedWings[wingId] = wing
                    wingsCount += 1
                }

                // 3. Parser flights.csv
                let flightsURL = extractedDir.appendingPathComponent("flights.csv")
                guard FileManager.default.fileExists(atPath: flightsURL.path) else {
                    throw NSError(domain: "ZipBackup", code: 5, userInfo: [NSLocalizedDescriptionKey: "flights.csv not found"])
                }

                let flightsCSV = try String(contentsOf: flightsURL, encoding: .utf8)
                let flightsRows = flightsCSV.components(separatedBy: "\n").dropFirst() // Skip header

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "dd/MM/yyyy HH:mm"

                var flights: [Flight] = []

                for row in flightsRows {
                    guard !row.isEmpty else { continue }
                    let cols = parseCSVRow(row)
                    guard cols.count >= 10 else { continue }

                    guard let startDate = dateFormatter.date(from: cols[1]),
                          let endDate = dateFormatter.date(from: cols[2]),
                          let durationSeconds = Int(cols[3]) else { continue }

                    let wingId = UUID(uuidString: cols[4])
                    let wing = wingId.flatMap { importedWings[$0] }

                    let flight = Flight(
                        wing: wing,
                        startDate: startDate,
                        endDate: endDate,
                        durationSeconds: durationSeconds,
                        spotName: cols[6].isEmpty ? nil : cols[6],
                        latitude: Double(cols[7]),
                        longitude: Double(cols[8])
                    )

                    if !cols[9].isEmpty {
                        flight.flightType = cols[9]
                    }
                    if cols.count >= 11 && !cols[10].isEmpty {
                        flight.notes = cols[10].replacingOccurrences(of: "\"", with: "")
                    }

                    flights.append(flight)
                }

                // 4. Insérer en base de données (sur main thread, SwiftData requirement)
                DispatchQueue.main.async {
                    do {
                        let modelContext = dataController.modelContext

                        // Si mode merge, vérifier les doublons
                        // Sinon, tout supprimer d'abord
                        if !mergeMode {
                            try modelContext.delete(model: Flight.self)
                            try modelContext.delete(model: Wing.self)
                        }

                        // Insérer les voiles
                        for wing in importedWings.values {
                            modelContext.insert(wing)
                        }

                        // Insérer les vols
                        for flight in flights {
                            modelContext.insert(flight)
                        }

                        try modelContext.save()

                        let summary = """
                        ✅ Import réussi !

                        Voiles importées: \(wingsCount)
                        Vols importés: \(flights.count)
                        Images restaurées: \(metadata.imagesCount)
                        Mode: \(mergeMode ? "Fusion" : "Remplacement")
                        """

                        completion(.success(summary))

                    } catch {
                        completion(.failure(error))
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Helper Functions

    private static func escapeCSV(_ string: String) -> String {
        string.replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func parseCSVRow(_ row: String) -> [String] {
        // Simple CSV parser (gère les guillemets basiques)
        var result: [String] = []
        var currentField = ""
        var inQuotes = false

        for char in row {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(currentField)
                currentField = ""
            } else {
                currentField.append(char)
            }
        }
        result.append(currentField)

        return result
    }

    private static func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHhmm"
        return formatter.string(from: date)
    }
}
