//
//  TrackExporter.swift
//  ParaFlightLog
//
//  Exports a flight's GPS track as GPX 1.1 or IGC.
//  Files are written to a temporary directory with a readable filename,
//  e.g. "2026-07-04_Cumbuco.gpx".
//  Target: iOS only
//

import Foundation

enum TrackExportError: LocalizedError {
    case noTrack

    var errorDescription: String? {
        switch self {
        case .noTrack:
            return "This flight has no GPS track to export."
        }
    }
}

enum TrackExporter {

    // MARK: - GPX

    /// Writes a GPX 1.1 file for the flight into a temporary directory.
    /// - Throws: TrackExportError.noTrack when the flight has no GPS points.
    static func gpxFile(for flight: Flight) throws -> URL {
        guard let track = flight.gpsTrack, !track.isEmpty else {
            throw TrackExportError.noTrack
        }

        let trackName = flight.spotName ?? "Flight"
        let timeFormatter = iso8601UTCFormatter()

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="ParaFlightLog" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(escapeXML(trackName))</name>
            <time>\(timeFormatter.string(from: flight.startDate))</time>
          </metadata>
          <trk>
            <name>\(escapeXML(trackName))</name>
            <trkseg>

        """

        for point in track {
            gpx += "      <trkpt lat=\"\(formatCoordinate(point.latitude))\" lon=\"\(formatCoordinate(point.longitude))\">\n"
            if let altitude = point.altitude {
                gpx += "        <ele>\(String(format: "%.1f", altitude))</ele>\n"
            }
            gpx += "        <time>\(timeFormatter.string(from: point.timestamp))</time>\n"
            gpx += "      </trkpt>\n"
        }

        gpx += """
            </trkseg>
          </trk>
        </gpx>
        """

        let url = temporaryFileURL(for: flight, fileExtension: "gpx")
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - IGC

    /// Writes a minimal valid IGC file for the flight into a temporary directory.
    /// Includes: A record, HFDTE date header, pilot header and B records.
    /// Pressure altitude falls back to GPS altitude (no barometer data stored).
    /// - Throws: TrackExportError.noTrack when the flight has no GPS points.
    static func igcFile(for flight: Flight) throws -> URL {
        guard let track = flight.gpsTrack, !track.isEmpty else {
            throw TrackExportError.noTrack
        }

        let utc = TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = utc
        dateFormatter.dateFormat = "ddMMyy"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = utc
        timeFormatter.dateFormat = "HHmmss"

        let flightDate = track.first?.timestamp ?? flight.startDate

        var igc = ""
        igc += "AXXX ParaFlightLog\r\n"
        igc += "HFDTE\(dateFormatter.string(from: flightDate))\r\n"
        igc += "HFPLTPILOTINCHARGE:ParaFlightLog\r\n"
        igc += "HFGTYGLIDERTYPE:\(sanitizeIGCText(flight.wing?.name ?? "Paraglider"))\r\n"

        for point in track {
            let time = timeFormatter.string(from: point.timestamp)
            let lat = igcLatitude(point.latitude)
            let lon = igcLongitude(point.longitude)
            // No barometric data stored: pressure altitude = GPS altitude fallback
            let gpsAlt = igcAltitude(point.altitude)
            igc += "B\(time)\(lat)\(lon)A\(gpsAlt)\(gpsAlt)\r\n"
        }

        let url = temporaryFileURL(for: flight, fileExtension: "igc")
        try igc.write(to: url, atomically: true, encoding: .ascii)
        return url
    }

    // MARK: - Filename Helpers

    /// Builds e.g. ".../2026-07-04_Cumbuco.gpx" in a temporary directory.
    private static func temporaryFileURL(for flight: Flight, fileExtension: String) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let datePart = dateFormatter.string(from: flight.startDate)
        let spotPart = sanitizeFilename(flight.spotName ?? "Flight")
        let filename = "\(datePart)_\(spotPart).\(fileExtension)"

        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    /// Keeps letters, digits, dashes and underscores; replaces everything else.
    private static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "Flight" : trimmed
    }

    // MARK: - XML Helpers

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func formatCoordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    // MARK: - IGC Helpers

    /// Latitude in IGC format: DDMMmmmN (degrees, minutes, thousandths of minutes)
    private static func igcLatitude(_ latitude: Double) -> String {
        let (degrees, minuteThousandths) = degreesAndMinuteThousandths(abs(latitude))
        let hemisphere = latitude >= 0 ? "N" : "S"
        return String(format: "%02d%05d%@", degrees, minuteThousandths, hemisphere)
    }

    /// Longitude in IGC format: DDDMMmmmE
    private static func igcLongitude(_ longitude: Double) -> String {
        let (degrees, minuteThousandths) = degreesAndMinuteThousandths(abs(longitude))
        let hemisphere = longitude >= 0 ? "E" : "W"
        return String(format: "%03d%05d%@", degrees, minuteThousandths, hemisphere)
    }

    /// Splits an absolute coordinate into whole degrees and minutes*1000,
    /// handling the 60.000-minute rollover from rounding.
    private static func degreesAndMinuteThousandths(_ absoluteValue: Double) -> (Int, Int) {
        var degrees = Int(absoluteValue)
        var minuteThousandths = Int(((absoluteValue - Double(degrees)) * 60.0 * 1000.0).rounded())
        if minuteThousandths >= 60000 {
            degrees += 1
            minuteThousandths = 0
        }
        return (degrees, minuteThousandths)
    }

    /// Altitude as a 5-digit IGC field, clamped to a valid range
    private static func igcAltitude(_ altitude: Double?) -> String {
        let value = Int((altitude ?? 0).rounded())
        let clamped = min(max(value, 0), 99999)
        return String(format: "%05d", clamped)
    }

    /// IGC headers are ASCII lines: strip CR/LF and non-ASCII characters
    private static func sanitizeIGCText(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.isASCII && $0 != "\r" && $0 != "\n" }.map(Character.init))
    }
}
