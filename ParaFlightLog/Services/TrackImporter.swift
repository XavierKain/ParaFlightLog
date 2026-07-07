//
//  TrackImporter.swift
//  ParaFlightLog
//
//  Imports IGC and GPX track files as flights (the import counterpart of
//  TrackExporter). Pure parsers are `nonisolated`; the import orchestrator
//  runs on the main actor (SwiftData requirement).
//  Target: iOS only
//

import Foundation
import SwiftData

// MARK: - Errors

nonisolated enum TrackImportError: LocalizedError {
    case unrecognizedFormat
    case invalidFile(String)
    case noFixes
    case noTimestamps
    case duplicate(existingDate: Date)

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "Unrecognized file format: expected an IGC or GPX track."
        case .invalidFile(let detail):
            return "The track file could not be read: \(detail)"
        case .noFixes:
            return "The track file contains no GPS fixes."
        case .noTimestamps:
            return "The track has no timestamps, so the flight duration cannot be determined."
        case .duplicate(let existingDate):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.locale = .autoupdatingCurrent
            return "A flight starting at \(formatter.string(from: existingDate)) already exists."
        }
    }
}

// MARK: - ParsedTrack

/// A fully parsed track with the same stats the Watch computes live.
/// Pure value type: `nonisolated` so parsing can run off the main actor.
nonisolated struct ParsedTrack {
    let points: [GPSTrackPoint]
    let startDate: Date
    let endDate: Date
    let durationSeconds: Int
    let startAltitude: Double?
    let maxAltitude: Double?
    let endAltitude: Double?
    let totalDistance: Double?   // meters
    let maxSpeed: Double?        // m/s
}

/// One selected file, parsed and ready to be confirmed in the import sheet.
nonisolated struct PendingTrackImport: Identifiable {
    let id = UUID()
    let filename: String
    let track: ParsedTrack
}

// MARK: - TrackImporter

enum TrackImporter {

    // MARK: - Format Detection

    /// Parses IGC or GPX data. Detects the format by file extension first,
    /// then by content sniffing (IGC "A" record vs "<?xml"/"<gpx").
    nonisolated static func parse(data: Data, filename: String) throws -> ParsedTrack {
        switch (filename as NSString).pathExtension.lowercased() {
        case "igc":
            return try parseIGC(data)
        case "gpx", "xml":
            return try parseGPX(data)
        default:
            break
        }

        // Content sniffing on the first non-empty line
        // (prefix cut can split a multi-byte char: isoLatin1 always decodes)
        var head = String(data: data.prefix(512), encoding: .utf8)
            ?? String(data: data.prefix(512), encoding: .isoLatin1)
            ?? ""
        // Strip a leading UTF-8 BOM: it would defeat every prefix check below.
        if head.hasPrefix("\u{FEFF}") {
            head.removeFirst()
        }
        let firstLine = head
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        if firstLine.hasPrefix("<?xml") || firstLine.lowercased().hasPrefix("<gpx") {
            return try parseGPX(data)
        }
        if firstLine.hasPrefix("A") {
            return try parseIGC(data)
        }
        throw TrackImportError.unrecognizedFormat
    }

    // MARK: - IGC Parsing

    /// Parses an IGC file: HFDTE date header (both "HFDTEDDMMYY" and
    /// "HFDTEDATE:DDMMYY" variants, with or without spaces) + B records.
    /// Timestamps are UTC; a decreasing time between fixes rolls over to the
    /// next day (midnight crossing). Per-point speed is derived from
    /// consecutive fixes (B records carry no speed).
    nonisolated static func parseIGC(_ data: Data) throws -> ParsedTrack {
        guard let content = String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw TrackImportError.invalidFile("not a text file")
        }

        let lines = content.components(separatedBy: .newlines)

        // --- HFDTE header -> flight date (UTC) ---
        var baseDate: Date?
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        for line in lines where line.hasPrefix("HFDTE") {
            // Variants: "HFDTE250716", "HFDTEDATE:250716,01", "HFDTE DATE:250716"
            var rest = String(line.dropFirst("HFDTE".count)).trimmingCharacters(in: .whitespaces)
            if rest.uppercased().hasPrefix("DATE:") {
                rest = String(rest.dropFirst("DATE:".count)).trimmingCharacters(in: .whitespaces)
            }
            let digits = rest.prefix(while: \.isNumber)
            guard digits.count >= 6,
                  let day = Int(digits.prefix(2)),
                  let month = Int(digits.dropFirst(2).prefix(2)),
                  let shortYear = Int(digits.dropFirst(4).prefix(2)),
                  (1...31).contains(day), (1...12).contains(month) else { continue }

            // IGC two-digit years: 00-79 -> 20xx, 80-99 -> 19xx
            let year = shortYear < 80 ? 2000 + shortYear : 1900 + shortYear
            baseDate = utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
            break
        }

        guard let flightDay = baseDate else {
            throw TrackImportError.invalidFile("missing HFDTE date header")
        }

        // --- B records -> fixes ---
        // B HHMMSS DDMMmmm[N/S] DDDMMmmm[E/W] [A/V] PPPPP GGGGG
        // offsets: 1-6     7-14           15-23        24    25-29 30-34
        var fixes: [(timestamp: Date, latitude: Double, longitude: Double, altitude: Double?)] = []
        var dayOffset: TimeInterval = 0
        var previousSeconds = -1

        for line in lines where line.hasPrefix("B") {
            let chars = Array(line)
            guard chars.count >= 35 else { continue }

            guard let hours = Int(String(chars[1...2])),
                  let minutes = Int(String(chars[3...4])),
                  let seconds = Int(String(chars[5...6])),
                  hours < 24, minutes < 60, seconds < 60,
                  let latDegrees = Int(String(chars[7...8])),
                  let latMinuteThousandths = Int(String(chars[9...13])),
                  let lonDegrees = Int(String(chars[15...17])),
                  let lonMinuteThousandths = Int(String(chars[18...22])) else { continue }

            let latHemisphere = chars[14]
            let lonHemisphere = chars[23]
            guard latHemisphere == "N" || latHemisphere == "S",
                  lonHemisphere == "E" || lonHemisphere == "W" else { continue }

            var latitude = Double(latDegrees) + Double(latMinuteThousandths) / 1000.0 / 60.0
            if latHemisphere == "S" { latitude = -latitude }
            var longitude = Double(lonDegrees) + Double(lonMinuteThousandths) / 1000.0 / 60.0
            if lonHemisphere == "W" { longitude = -longitude }
            guard abs(latitude) <= 90, abs(longitude) <= 180 else { continue }

            // Altitude: GPS altitude for 3D fixes ("A"), else pressure altitude
            let validity = chars[24]
            let pressureAltitude = Int(String(chars[25...29]).trimmingCharacters(in: .whitespaces))
            let gpsAltitude = Int(String(chars[30...34]).trimmingCharacters(in: .whitespaces))
            let altitude: Double?
            if validity == "A", let gps = gpsAltitude, gps != 0 {
                altitude = Double(gps)
            } else if let pressure = pressureAltitude {
                altitude = Double(pressure)
            } else {
                altitude = gpsAltitude.map(Double.init)
            }

            // Midnight rollover: the time-of-day decreasing means a new UTC day
            // (60 s of tolerance so slightly out-of-order fixes don't trigger it).
            // Only a jump back of more than 12 h is a genuine midnight crossing
            // (e.g. 23:59 -> 00:00); a smaller backwards jump is a garbled fix —
            // skip it instead of shifting the whole rest of the track by a day.
            let secondsOfDay = hours * 3600 + minutes * 60 + seconds
            if previousSeconds >= 0 && secondsOfDay + 60 < previousSeconds {
                if previousSeconds - secondsOfDay > 43_200 {
                    dayOffset += 86400
                } else {
                    continue
                }
            }
            previousSeconds = secondsOfDay

            let timestamp = flightDay.addingTimeInterval(dayOffset + Double(secondsOfDay))
            fixes.append((timestamp, latitude, longitude, altitude))
        }

        guard !fixes.isEmpty else {
            throw TrackImportError.noFixes
        }

        return try makeParsedTrack(from: fixes)
    }

    // MARK: - GPX Parsing

    /// Parses a GPX file with Foundation's XMLParser: the first <trk> (all its
    /// <trkseg>s), trkpt lat/lon attributes + optional <ele> and <time>
    /// (ISO 8601 with or without fractional seconds). Points without a time
    /// get one interpolated from their timed neighbors; untimed points before
    /// the first / after the last timed point are dropped. When NO point has
    /// a time the file cannot become a flight -> `.noTimestamps`.
    nonisolated static func parseGPX(_ data: Data) throws -> ParsedTrack {
        let delegate = GPXTrackParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        if delegate.rawPoints.isEmpty {
            if let error = parser.parserError {
                throw TrackImportError.invalidFile(error.localizedDescription)
            }
            throw TrackImportError.noFixes
        }

        let raw = delegate.rawPoints
        guard raw.contains(where: { $0.time != nil }) else {
            throw TrackImportError.noTimestamps
        }

        // Interpolate missing timestamps between timed neighbors; drop the
        // untimed edges (nothing to interpolate from).
        let timedIndices = raw.indices.filter { raw[$0].time != nil }
        guard let firstTimed = timedIndices.first, let lastTimed = timedIndices.last else {
            throw TrackImportError.noTimestamps
        }

        var fixes: [(timestamp: Date, latitude: Double, longitude: Double, altitude: Double?)] = []
        var previousTimedIndex = firstTimed
        for index in firstTimed...lastTimed {
            let point = raw[index]
            let timestamp: Date
            if let time = point.time {
                timestamp = time
                previousTimedIndex = index
            } else {
                // Linear interpolation by position between the two timed neighbors
                guard let nextTimedIndex = timedIndices.first(where: { $0 > index }),
                      let before = raw[previousTimedIndex].time,
                      let after = raw[nextTimedIndex].time else { continue }
                let fraction = Double(index - previousTimedIndex) / Double(nextTimedIndex - previousTimedIndex)
                timestamp = before.addingTimeInterval(after.timeIntervalSince(before) * fraction)
            }
            fixes.append((timestamp, point.latitude, point.longitude, point.elevation))
        }

        guard !fixes.isEmpty else {
            throw TrackImportError.noFixes
        }

        return try makeParsedTrack(from: fixes)
    }

    // MARK: - Stats (same rules as the Watch tracker)

    /// Builds the final ParsedTrack from raw fixes: derives per-point speed
    /// from consecutive fixes, sums the haversine distance (segments < 2 m are
    /// GPS jitter and ignored) and extracts the altitude/speed extremes.
    private nonisolated static func makeParsedTrack(
        from rawFixes: [(timestamp: Date, latitude: Double, longitude: Double, altitude: Double?)]
    ) throws -> ParsedTrack {
        let fixes = rawFixes.sorted { $0.timestamp < $1.timestamp }
        guard let first = fixes.first, let last = fixes.last else {
            throw TrackImportError.noFixes
        }

        var points: [GPSTrackPoint] = []
        points.reserveCapacity(fixes.count)
        var totalDistance: Double = 0
        var maxSpeed: Double?

        for (index, fix) in fixes.enumerated() {
            var speed: Double? = nil
            if index > 0 {
                let previous = fixes[index - 1]
                let distance = haversineDistance(
                    lat1: previous.latitude, lon1: previous.longitude,
                    lat2: fix.latitude, lon2: fix.longitude
                )
                // < 2 m between fixes is GPS jitter, not movement
                if distance >= 2 {
                    totalDistance += distance
                }
                let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0 {
                    let derived = distance / dt
                    // Filter aberrant jumps (> 100 m/s = 360 km/h, same cap as the Watch)
                    if derived < 100 {
                        speed = derived
                        if derived > (maxSpeed ?? 0) {
                            maxSpeed = derived
                        }
                    }
                }
            }
            points.append(GPSTrackPoint(
                timestamp: fix.timestamp,
                latitude: fix.latitude,
                longitude: fix.longitude,
                altitude: fix.altitude,
                speed: speed
            ))
        }

        let altitudes = fixes.compactMap(\.altitude)
        let duration = max(0, Int(last.timestamp.timeIntervalSince(first.timestamp).rounded()))

        return ParsedTrack(
            points: points,
            startDate: first.timestamp,
            endDate: last.timestamp,
            durationSeconds: duration,
            startAltitude: first.altitude ?? altitudes.first,
            maxAltitude: altitudes.max(),
            endAltitude: last.altitude ?? altitudes.last,
            totalDistance: fixes.count >= 2 ? totalDistance : nil,
            maxSpeed: maxSpeed
        )
    }

    /// Great-circle distance between two coordinates in meters.
    private nonisolated static func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = (lat2 - lat1) * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Import Orchestration (main actor: SwiftData)

    /// Imports one track file end to end: reads the (possibly security-scoped)
    /// URL, parses it, and creates the flight.
    @MainActor
    static func importTrack(from url: URL, wing: Wing?, dataController: DataController) throws -> Flight {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        let parsed = try parse(data: data, filename: url.lastPathComponent)
        return try createFlight(from: parsed, wing: wing, flightType: nil, dataController: dataController)
    }

    /// Creates and persists a Flight from a parsed track.
    /// Dedup: throws `.duplicate` when a flight already starts within ±60 s of
    /// the track's start (re-importing the same file, or a track of a flight
    /// already logged by the Watch). Attaches the GPS track and stats, sets
    /// the takeoff coordinates from the first fix, resolves the spot and fires
    /// the best-effort takeoff weather snapshot.
    @MainActor
    @discardableResult
    static func createFlight(from parsed: ParsedTrack, wing: Wing?, flightType: FlightType?, dataController: DataController) throws -> Flight {
        if let existing = existingFlight(near: parsed.startDate, dataController: dataController) {
            logInfo("Track import skipped: a flight already starts at \(existing.startDate)", category: .dataImport)
            throw TrackImportError.duplicate(existingDate: existing.startDate)
        }

        let firstPoint = parsed.points.first
        let flight = Flight(
            wing: wing,
            startDate: parsed.startDate,
            endDate: parsed.endDate,
            durationSeconds: parsed.durationSeconds,
            latitude: firstPoint?.latitude,
            longitude: firstPoint?.longitude,
            flightType: flightType?.rawValue,
            startAltitude: parsed.startAltitude,
            maxAltitude: parsed.maxAltitude,
            endAltitude: parsed.endAltitude,
            totalDistance: parsed.totalDistance,
            maxSpeed: parsed.maxSpeed
        )
        flight.setGPSTrack(parsed.points)

        dataController.modelContext.insert(flight)
        dataController.assignSpot(to: flight)
        dataController.saveContext()

        // Best-effort post-save hooks (takeoff weather snapshot + opt-in
        // community share), fire-and-forget like every other flight save
        // path — but PACED through a serial chain so a batch import of many
        // files trickles its Open-Meteo/Appwrite calls instead of bursting.
        schedulePostSaveHooks(flightId: flight.id, dataController: dataController)

        logInfo("Track imported: \(flight.durationFormatted), \(parsed.points.count) GPS points, spot \(flight.spotName ?? "unresolved")", category: .dataImport)
        return flight
    }

    // MARK: - Post-save hook pacing

    /// Tail of the serial chain spacing post-save hooks ~400 ms apart.
    /// MainActor-confined: only touched from `schedulePostSaveHooks`.
    @MainActor
    private static var lastHookTask: Task<Void, Never>?

    /// Enqueues the fire-and-forget post-save hooks (weather snapshot +
    /// community share) for one flight BEHIND the previous flight's hooks,
    /// with ~400 ms spacing, so a 100-file import doesn't hammer Open-Meteo
    /// and Appwrite with 100 simultaneous requests. Single imports only pay
    /// one 400 ms delay on best-effort enrichment — never on the save itself.
    @MainActor
    private static func schedulePostSaveHooks(flightId: UUID, dataController: DataController) {
        let previous = lastHookTask
        lastHookTask = Task { [weak dataController] in
            await previous?.value
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4 s
            guard let dataController,
                  let flight = dataController.findFlight(byId: flightId) else { return }
            // Skipped automatically when disabled or when the flight is
            // > 90 days old / not eligible for sharing.
            WeatherService.shared.captureSnapshot(for: flightId, dataController: dataController)
            CommunityService.shared.shareFlightIfEnabled(flight, dataController: dataController)
        }
    }

    /// First stored flight whose start time is within ±60 s of `date`.
    @MainActor
    private static func existingFlight(near date: Date, dataController: DataController) -> Flight? {
        let lower = date.addingTimeInterval(-60)
        let upper = date.addingTimeInterval(60)
        var descriptor = FetchDescriptor<Flight>(
            predicate: #Predicate<Flight> { $0.startDate >= lower && $0.startDate <= upper }
        )
        descriptor.fetchLimit = 1
        do {
            return try dataController.modelContext.fetch(descriptor).first
        } catch {
            logError("Duplicate check failed: \(error)", category: .dataImport)
            return nil
        }
    }
}

// MARK: - GPX XMLParser Delegate

/// Collects the trkpts of the FIRST <trk> (all its segments).
/// `nonisolated`: driven synchronously by parseGPX, potentially off the main actor.
private nonisolated final class GPXTrackParserDelegate: NSObject, XMLParserDelegate {

    struct RawPoint {
        let latitude: Double
        let longitude: Double
        var elevation: Double?
        var time: Date?
    }

    var rawPoints: [RawPoint] = []

    private var insideTrack = false
    private var finishedFirstTrack = false
    private var currentPoint: RawPoint?
    private var textBuffer = ""
    private var capturingText = false

    // <time> values: ISO 8601, with or without fractional seconds
    private let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !finishedFirstTrack else { return }

        switch elementName {
        case "trk":
            insideTrack = true
        case "trkpt":
            guard insideTrack,
                  let latString = attributeDict["lat"], let latitude = Double(latString),
                  let lonString = attributeDict["lon"], let longitude = Double(lonString),
                  abs(latitude) <= 90, abs(longitude) <= 180 else { return }
            currentPoint = RawPoint(latitude: latitude, longitude: longitude)
        case "ele", "time":
            guard currentPoint != nil else { return }
            textBuffer = ""
            capturingText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingText {
            textBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !finishedFirstTrack else { return }

        switch elementName {
        case "trk":
            insideTrack = false
            finishedFirstTrack = true
        case "trkpt":
            if let point = currentPoint {
                rawPoints.append(point)
            }
            currentPoint = nil
        case "ele":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            currentPoint?.elevation = Double(value)
            capturingText = false
        case "time":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            currentPoint?.time = plainFormatter.date(from: value) ?? fractionalFormatter.date(from: value)
            capturingText = false
        default:
            break
        }
    }
}
