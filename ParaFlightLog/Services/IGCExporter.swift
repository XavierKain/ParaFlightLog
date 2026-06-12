//
//  IGCExporter.swift
//  ParaFlightLog
//
//  Générateur de fichiers IGC (format FAI/IGC standard) depuis un vol SoarX.
//  Référence : "IGC Flight Recorder Specification" (FAI/IGC).
//  Toutes les heures et dates sont exprimées en UTC, comme l'exige le format.
//

import Foundation

// MARK: - IGCExporter

enum IGCExporter {

    // MARK: - API publique

    /// Génère le fichier IGC d'un vol. Retourne l'URL du fichier temporaire .igc, ou nil si pas de trace.
    static func exportIGC(flight: Flight, pilotName: String?) -> URL? {
        // Pas de trace GPS ou trace trop courte → rien à exporter
        guard let track = flight.gpsTrack, track.count >= 2 else { return nil }

        // Les points doivent être ordonnés chronologiquement pour des B records valides
        let sortedTrack = track.sorted { $0.timestamp < $1.timestamp }

        var lines: [String] = []

        // MARK: A record (identification du logger)
        // "XXX" = code constructeur non officiel (logger non certifié), suivi de l'identifiant SoarX
        lines.append("AXXXSOARX")

        // MARK: H records (en-têtes)
        lines.append("HFDTE\(headerDateFormatter.string(from: flight.startDate))")
        lines.append("HFPLTPILOTINCHARGE:\(pilotName ?? "")")
        lines.append("HFGTYGLIDERTYPE:\(gliderType(for: flight.wing))")
        lines.append("HFGIDGLIDERID:")
        lines.append("HFDTM100GPSDATUM:WGS-1984")
        lines.append("HFRFWFIRMWAREVERSION:SoarX")
        lines.append("HFFTYFRTYPE:SoarX,iOS")
        if let spot = flight.spotName, !spot.isEmpty {
            lines.append("HOSITSITE:\(spot)")
        }

        // MARK: B records (un par point GPS)
        for point in sortedTrack {
            lines.append(bRecord(for: point))
        }

        // MARK: G record (signature)
        // Pas de signature cryptographique valide possible côté app → placeholder explicite
        lines.append("GSOARXUNSIGNED")

        // Le format IGC utilise des fins de ligne CRLF
        let content = lines.joined(separator: "\r\n") + "\r\n"

        // MARK: Écriture du fichier temporaire
        let fileName = "SoarX_\(fileNameDateFormatter.string(from: flight.startDate)).igc"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.write(to: url, atomically: true, encoding: .ascii)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Formatage des enregistrements

    /// Construit un B record IGC : B + HHMMSS + lat + lon + validité + alt pression + alt GPS
    /// Exemple : B1101355206343N00006198WA0058700558
    private static func bRecord(for point: GPSTrackPoint) -> String {
        let time = bRecordTimeFormatter.string(from: point.timestamp)
        let lat = formatLatitude(point.latitude)
        let lon = formatLongitude(point.longitude)

        // "A" = fix 3D valide (altitude connue), "V" = fix sans altitude
        let validity = point.altitude != nil ? "A" : "V"

        // Altitude GPS en mètres, 5 chiffres zéro-paddés, clampée ≥ 0
        let altitude = formatAltitude(point.altitude)

        // Pas de capteur baro sur iPhone : on duplique l'altitude GPS en altitude pression,
        // pratique courante des loggers téléphone (00000 si inconnue)
        return "B\(time)\(lat)\(lon)\(validity)\(altitude)\(altitude)"
    }

    /// Latitude au format IGC : DDMMmmmN/S
    /// (degrés sur 2 chiffres, minutes décimales ×1000 sur 5 chiffres)
    /// Ex : 52.105716 → "5206343N" (52° + 0.105716×60 = 6.34296' → 06343)
    static func formatLatitude(_ latitude: Double) -> String {
        let (degrees, milliMinutes, isNegative) = decompose(abs: min(max(latitude, -90), 90))
        let hemisphere = isNegative ? "S" : "N"
        return String(format: "%02d%05d%@", degrees, milliMinutes, hemisphere)
    }

    /// Longitude au format IGC : DDDMMmmmE/W
    /// (degrés sur 3 chiffres, minutes décimales ×1000 sur 5 chiffres)
    /// Ex : -0.103300 → "00006198W" (0° + 0.1033×60 = 6.198' → 06198)
    static func formatLongitude(_ longitude: Double) -> String {
        let (degrees, milliMinutes, isNegative) = decompose(abs: min(max(longitude, -180), 180))
        let hemisphere = isNegative ? "W" : "E"
        return String(format: "%03d%05d%@", degrees, milliMinutes, hemisphere)
    }

    /// Décompose une coordonnée signée en (degrés entiers, millièmes de minutes, signe).
    /// Gère le report en cas d'arrondi à 60.000' (ex : 51.99999° → 52° 00.000').
    private static func decompose(abs value: Double) -> (degrees: Int, milliMinutes: Int, isNegative: Bool) {
        let isNegative = value < 0
        let absolute = Swift.abs(value)
        var degrees = Int(absolute)
        // Minutes décimales ×1000, arrondies au plus proche
        var milliMinutes = Int(((absolute - Double(degrees)) * 60.0 * 1000.0).rounded())
        // Report : 60.000' = 1 degré supplémentaire
        if milliMinutes >= 60_000 {
            milliMinutes -= 60_000
            degrees += 1
        }
        return (degrees, milliMinutes, isNegative)
    }

    /// Altitude en mètres sur 5 chiffres zéro-paddés, clampée ≥ 0 ("00000" si inconnue)
    private static func formatAltitude(_ altitude: Double?) -> String {
        guard let altitude else { return "00000" }
        let clamped = max(0, Int(altitude.rounded()))
        return String(format: "%05d", min(clamped, 99_999))
    }

    /// Type de voile pour le header HFGTY (nom + taille si dispo)
    private static func gliderType(for wing: Wing?) -> String {
        guard let wing else { return "" }
        if let size = wing.size, !size.isEmpty {
            return "\(wing.name) \(size)"
        }
        return wing.name
    }

    // MARK: - Formatters (UTC obligatoire pour le format IGC)

    /// Date du header HFDTE : DDMMYY (UTC)
    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "ddMMyy"
        return formatter
    }()

    /// Heure des B records : HHMMSS (UTC)
    private static let bRecordTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    /// Date pour le nom de fichier : SoarX_yyyy-MM-dd_HHmm.igc (UTC)
    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter
    }()
}

// MARK: - Auto-test (DEBUG)

#if DEBUG
extension IGCExporter {
    /// Vérifie le formatage lat/lon sur des valeurs connues. Retourne true si tout passe.
    static func _selfTest() -> Bool {
        // (valeur, résultat attendu)
        let latitudeCases: [(Double, String)] = [
            (52.105716, "5206343N"),   // 52° + 0.105716×60 = 6.34296' → 06343
            (-33.856784, "3351407S"),  // 33° + 0.856784×60 = 51.40704' → 51407
            (0.0, "0000000N"),
            (45.999999, "4600000N"),   // arrondi 59.99994' → 60.000' → report sur les degrés
        ]
        let longitudeCases: [(Double, String)] = [
            (-0.103300, "00006198W"),  // 0° + 0.1033×60 = 6.198' → 06198
            (151.215297, "15112918E"), // 151° + 0.215297×60 = 12.91782' → 12918
            (-122.419400, "12225164W"),// 122° + 0.4194×60 = 25.164' → 25164
            (0.0, "00000000E"),
        ]

        for (value, expected) in latitudeCases {
            let result = formatLatitude(value)
            guard result == expected else {
                print("IGCExporter._selfTest: latitude \(value) → \(result), attendu \(expected)")
                return false
            }
        }
        for (value, expected) in longitudeCases {
            let result = formatLongitude(value)
            guard result == expected else {
                print("IGCExporter._selfTest: longitude \(value) → \(result), attendu \(expected)")
                return false
            }
        }
        return true
    }
}
#endif
