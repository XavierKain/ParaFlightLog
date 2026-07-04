//
//  GPSTrackCompaction.swift
//  ParaFlightLogWatch Watch App
//
//  Single shared GPS track compaction used by WatchLocationService (in-memory
//  track) and FlightSessionManager (persisted crash-recovery track), so both
//  agree on the same limit and the same strategy.
//  Target: Watch only
//

import Foundation

enum GPSTrackCompaction {
    /// Maximum number of GPS points kept (in memory and persisted).
    /// 500 points * 5 seconds = ~42 minutes at full resolution; longer flights
    /// degrade the oldest half progressively.
    static let maxPoints = 500

    /// Compaction triggers at 80% of the limit to keep headroom.
    static let compactionThreshold = 400

    /// Returns a compacted copy of the track when it reaches the threshold.
    /// Strategy: keep 1 point out of 2 in the older half (reduced resolution)
    /// and every point in the recent half (full resolution).
    /// Below the threshold the track is returned unchanged.
    static func compact(_ points: [GPSTrackPoint]) -> [GPSTrackPoint] {
        let count = points.count
        guard count >= compactionThreshold else { return points }

        var compacted: [GPSTrackPoint] = []
        compacted.reserveCapacity(count * 3 / 4)

        let halfCount = count / 2

        // Older half: one point out of 2
        for i in stride(from: 0, to: halfCount, by: 2) {
            compacted.append(points[i])
        }

        // Recent half: all points
        for i in halfCount..<count {
            compacted.append(points[i])
        }

        return compacted
    }
}
