//
//  TestImport.swift
//  ParaFlightLog
//
//  Test script pour vérifier l'import du backup existant
//

import Foundation

func testImportBackup() {
    let backupPath = "/Users/xavier/VSCode3/ParaFlightLog/Backup/ParaFlightLog_Backup_2025-12-03_121204.paraflightlog"
    let backupURL = URL(fileURLWithPath: backupPath)

    print("🧪 Testing backup import...")
    print("📂 Backup path: \(backupPath)")

    // Vérifier que le dossier existe
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: backupPath, isDirectory: &isDirectory)

    print("✅ Exists: \(exists)")
    print("📁 Is directory: \(isDirectory.boolValue)")

    // Lister le contenu
    if exists, isDirectory.boolValue {
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: backupPath)
            print("📋 Contents:")
            for item in contents {
                print("  - \(item)")
            }

            // Vérifier metadata.json
            let metadataPath = backupPath + "/metadata.json"
            if fileManager.fileExists(atPath: metadataPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("✅ metadata.json valid:")
                    print("   Wings: \(json["wingsCount"] ?? 0)")
                    print("   Flights: \(json["flightsCount"] ?? 0)")
                    print("   Images: \(json["imagesCount"] ?? 0)")
                }
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }
}
