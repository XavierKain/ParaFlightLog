//
//  FlightOutbox.swift
//  ParaFlightLogWatch Watch App
//
//  Persistent outbox for flights waiting to be delivered to the iPhone.
//  Each pending FlightDTO is stored as an individual JSON file in
//  Documents/Outbox so a flight is never lost, even if the app is killed
//  before delivery. GPS tracks can be large, hence files instead of UserDefaults.
//  A flight is removed ONLY when the iPhone confirms the save
//  (sendMessage reply with flightSaved == true).
//  Target: Watch only
//

import Foundation

/// Thread-safe persistent store for flights pending delivery to the iPhone.
/// A flight is added BEFORE any delivery attempt and only removed once the
/// iPhone has confirmed the SAVE via a sendMessage reply containing
/// flightSaved == true. Completion of a userInfo transfer is NOT enough:
/// it only means WatchConnectivity delivered the payload, not that the
/// iPhone persisted the flight. Redundant delivery is safe: the iPhone
/// deduplicates flights by id and replies flightSaved == true for flights
/// it already saved, so retries converge and the outbox drains.
///
/// nonisolated: safe to call from any queue (WCSession reply/error handlers
/// run on a background queue); all file access is serialized internally.
nonisolated final class FlightOutbox {
    static let shared = FlightOutbox()

    /// Serial queue guaranteeing thread-safe file access
    private let queue = DispatchQueue(label: "com.paraflightlog.flightoutbox", qos: .utility)
    private let directoryURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directoryURL = documents.appendingPathComponent("Outbox", isDirectory: true)
    }

    // MARK: - API

    /// Persists a flight to disk. Synchronous: when this returns `true`, the
    /// flight is safely on disk and the live tracking session can be cleared.
    /// On `false` (disk full, encode failure) the caller must NOT clear the
    /// tracking session — it stays recoverable via FlightSessionManager.
    @discardableResult
    func add(_ dto: FlightDTO) -> Bool {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(dto)
                try data.write(to: fileURL(for: dto.id), options: .atomic)
                watchLogInfo("Flight \(dto.id.uuidString) written to outbox", category: .watchSync)
                return true
            } catch {
                watchLogError("Failed to write flight \(dto.id.uuidString) to outbox: \(error)", category: .watchSync)
                return false
            }
        }
    }

    /// Returns all flights still waiting for delivery, oldest first.
    func pending() -> [FlightDTO] {
        queue.sync {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }

            var flights: [FlightDTO] = []
            for url in urls where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let dto = try JSONDecoder().decode(FlightDTO.self, from: data)
                    flights.append(dto)
                } catch {
                    // Keep the file (never delete flight data automatically),
                    // just skip it for this delivery pass.
                    watchLogError("Failed to decode outbox file \(url.lastPathComponent): \(error)", category: .watchSync)
                }
            }
            return flights.sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Removes a flight after the iPhone confirmed the save
    /// (sendMessage reply with flightSaved == true).
    func remove(id: UUID) {
        queue.sync {
            let url = fileURL(for: id)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
                watchLogInfo("Flight \(id.uuidString) removed from outbox (delivered)", category: .watchSync)
            } catch {
                watchLogError("Failed to remove flight \(id.uuidString) from outbox: \(error)", category: .watchSync)
            }
        }
    }

    // MARK: - Helpers

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
