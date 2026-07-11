//
//  ReplayEngine.swift
//  ParaFlightLog
//
//  Pure, deterministic math for the 3D flight replay. Everything here is
//  `nonisolated` and free of SwiftUI / UIKit so it can run off the main actor
//  and be exercised by a unit-test suite (see the exposed pure functions:
//  `resample`, `interpolate(at:)`, `headingAt(_:)`, `varioAt(_:)`,
//  `totalDuration`).
//
//  The engine turns a raw, unevenly-sampled GPS track into a *silky* motion
//  path:
//    1. Position and altitude are interpolated with Catmull-Rom cubic Hermite
//       splines (time-parameterised, so uneven sample spacing is handled).
//    2. The spline is resampled onto a fixed internal timestep — the view then
//       does a cheap O(1) lookup + lerp per frame instead of per-tick spline
//       math.
//    3. Heading is derived from a look-ahead bearing and smoothed by averaging
//       unit vectors over a window (wrap-safe, shortest-arc, no 359°→1° spin).
//    4. Vario is a windowed derivative of the smoothed altitude.
//
//  Target: iOS only
//

import Foundation
import CoreLocation
import CoreGraphics

// MARK: - Value types

/// Interpolated state of the pilot at one instant. Pure data — the view maps
/// `verticalSpeed` to a color, this stays UI-free.
nonisolated struct ReplaySample {
    /// Seconds since the start of the track.
    let time: TimeInterval
    let coordinate: CLLocationCoordinate2D
    /// Metres. `nil` only when the whole track lacks altitude.
    let altitude: Double?
    /// Ground speed in m/s (recorded, or derived from the path when absent).
    let speed: Double?
    /// Vertical speed / vario in m/s. `nil` when the track lacks altitude.
    let verticalSpeed: Double?
    /// Course over ground in degrees, 0 = north, clockwise.
    let heading: Double
}

/// A run of consecutive path points sharing a similar vario, pre-grouped so the
/// full track renders as a handful of colored polylines (overview + the
/// progressive flown gradient).
nonisolated struct VarioRun: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let meanVario: Double
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// One slice of the comet trail (the recent-seconds tail behind the pilot),
/// colored by vario and faded by `ageFactor` (0 = oldest, 1 = newest).
nonisolated struct TrailSlice: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let meanVario: Double
    let ageFactor: Double
}

// MARK: - ReplayEngine

/// Precomputes the smoothed replay path once, then answers cheap per-frame
/// queries. Build it on any actor; every method is pure and deterministic.
nonisolated struct ReplayEngine {

    /// Absolute wall-clock time of the first track point (for the HUD clock).
    let trackStart: Date
    /// Length of the flight in seconds (0 for a degenerate single-instant track).
    let totalDuration: TimeInterval
    /// Spacing of the internal resampled grid, in seconds (0 when static).
    let timestep: TimeInterval

    let hasAltitude: Bool
    let hasSpeed: Bool

    /// Raw (un-smoothed) coordinates — used for cheap context / bounds.
    let rawCoordinates: [CLLocationCoordinate2D]
    /// Center of the flight's bounding box (overview framing).
    let centerCoordinate: CLLocationCoordinate2D
    /// A camera distance that frames the whole flight from above.
    let overviewDistance: Double
    /// Normalised altitude curve (x = time 0…1, y = altitude 0…1) for the
    /// timeline scrubber. Empty when the track has no altitude.
    let altitudeProfile: [CGPoint]

    /// Dense resampled path on the fixed grid. `private` so callers go through
    /// the pure query API.
    private let samples: [ReplaySample]
    private let runs: [RunMeta]

    private struct RunMeta { let range: ClosedRange<Int>; let meanVario: Double }

    /// Cap on internal samples so a multi-hour, 10k-point track stays bounded
    /// in memory; the timestep grows for very long flights.
    private static let maxSamples = 8000
    /// Target grid spacing before the cap kicks in.
    private static let desiredTimestep: TimeInterval = 0.3

    // MARK: Construction

    init(points rawPoints: [GPSTrackPoint]) {
        // Sort so interpolation is monotonic regardless of input ordering.
        let sorted = rawPoints.sorted { $0.timestamp < $1.timestamp }
        let start = sorted.first?.timestamp ?? Date()
        trackStart = start

        let offsets = sorted.map { $0.timestamp.timeIntervalSince(start) }
        let duration = max(0, offsets.last ?? 0)
        totalDuration = duration

        rawCoordinates = sorted.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let (center, distance) = Self.computeBounds(rawCoordinates)
        centerCoordinate = center
        overviewDistance = distance

        hasAltitude = sorted.contains { $0.altitude != nil }
        hasSpeed = sorted.contains { $0.speed != nil }

        // Choose a uniform grid: n intervals, timestep = duration / n, capped.
        let ts: TimeInterval
        if duration > 0 {
            let n = max(1, min(Self.maxSamples, Int((duration / Self.desiredTimestep).rounded())))
            ts = duration / Double(n)
        } else {
            ts = 0
        }
        timestep = ts

        samples = Self.buildSamples(sorted: sorted, offsets: offsets, timestep: ts)
        runs = Self.buildRuns(samples)
        altitudeProfile = Self.buildProfile(samples, duration: duration)
    }

    // MARK: - Pure query API (test surface)

    /// Number of internal grid samples (handy for tests / diagnostics).
    var sampleCount: Int { samples.count }

    /// Interpolated pilot state at an arbitrary time (clamped to the flight).
    /// O(1): the grid is uniform, so the bracketing samples are found by
    /// division, then values are lerped (heading along the shortest arc).
    func interpolate(at time: TimeInterval) -> ReplaySample {
        guard let first = samples.first else {
            return ReplaySample(time: 0, coordinate: centerCoordinate,
                                altitude: nil, speed: nil, verticalSpeed: nil, heading: 0)
        }
        guard samples.count >= 2, timestep > 0 else { return first }

        let t = min(max(time, 0), totalDuration)
        let u = t / timestep
        var i = Int(u.rounded(.down))
        if i < 0 { i = 0 }
        if i >= samples.count - 1 { i = samples.count - 2 }
        let f = min(max(u - Double(i), 0), 1)

        let a = samples[i]
        let b = samples[i + 1]
        let coordinate = CLLocationCoordinate2D(
            latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * f,
            longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * f
        )
        return ReplaySample(
            time: t,
            coordinate: coordinate,
            altitude: Self.lerpOptional(a.altitude, b.altitude, f),
            speed: Self.lerpOptional(a.speed, b.speed, f),
            verticalSpeed: Self.lerpOptional(a.verticalSpeed, b.verticalSpeed, f),
            heading: Self.lerpAngle(from: a.heading, to: b.heading, factor: f)
        )
    }

    /// Smoothed heading (degrees, 0 = north) at a given time.
    func headingAt(_ time: TimeInterval) -> Double { interpolate(at: time).heading }

    /// Smoothed vario (m/s) at a given time, or `nil` without altitude data.
    func varioAt(_ time: TimeInterval) -> Double? { interpolate(at: time).verticalSpeed }

    /// Resamples a raw track onto a fixed timestep. Exposed as a pure static so
    /// tests can feed synthetic tracks and assert on the smoothed output.
    static func resample(points: [GPSTrackPoint], timestep: TimeInterval) -> [ReplaySample] {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        let start = sorted.first?.timestamp ?? Date()
        let offsets = sorted.map { $0.timestamp.timeIntervalSince(start) }
        return buildSamples(sorted: sorted, offsets: offsets, timestep: timestep)
    }

    // MARK: - Track rendering helpers (pure)

    /// Whole-track vario gradient (used in overview mode).
    var varioRuns: [VarioRun] {
        var out: [VarioRun] = []
        out.reserveCapacity(runs.count)
        for (i, meta) in runs.enumerated() {
            // Extend by one sample so consecutive runs visually connect.
            let last = min(meta.range.upperBound + 1, samples.count - 1)
            guard meta.range.lowerBound <= last else { continue }
            let coords = (meta.range.lowerBound...last).map { samples[$0].coordinate }
            guard coords.count >= 2 else { continue }
            out.append(VarioRun(
                id: i,
                coordinates: coords,
                meanVario: meta.meanVario,
                startTime: samples[meta.range.lowerBound].time,
                endTime: samples[min(meta.range.upperBound, samples.count - 1)].time
            ))
        }
        return out
    }

    /// The *flown* part of the track up to `time`, as vario-colored runs — the
    /// progressive gradient that grows as the replay plays. The run containing
    /// the playhead is truncated at the exact interpolated position.
    func flownRuns(upTo time: TimeInterval) -> [VarioRun] {
        guard samples.count >= 2, timestep > 0 else { return [] }
        let t = min(max(time, 0), totalDuration)
        let idx = min(Int((t / timestep).rounded(.down)), samples.count - 1)

        var out: [VarioRun] = []
        var id = 0
        for meta in runs {
            if meta.range.lowerBound > idx { break }
            if meta.range.upperBound <= idx {
                let last = min(meta.range.upperBound + 1, samples.count - 1)
                let coords = (meta.range.lowerBound...last).map { samples[$0].coordinate }
                if coords.count >= 2 {
                    out.append(VarioRun(id: id, coordinates: coords, meanVario: meta.meanVario,
                                        startTime: samples[meta.range.lowerBound].time,
                                        endTime: samples[min(meta.range.upperBound, samples.count - 1)].time))
                }
            } else {
                // Partial run: up to the playhead, then the exact current point.
                var coords = (meta.range.lowerBound...idx).map { samples[$0].coordinate }
                coords.append(interpolate(at: t).coordinate)
                if coords.count >= 2 {
                    out.append(VarioRun(id: id, coordinates: coords, meanVario: meta.meanVario,
                                        startTime: samples[meta.range.lowerBound].time, endTime: t))
                }
                break
            }
            id += 1
        }
        return out
    }

    /// The *unflown* remainder from `time` to the end, as a faint context line.
    func remainderCoordinates(from time: TimeInterval) -> [CLLocationCoordinate2D] {
        guard samples.count >= 2, timestep > 0 else { return samples.map { $0.coordinate } }
        let t = min(max(time, 0), totalDuration)
        let idx = min(Int((t / timestep).rounded(.up)), samples.count - 1)
        var coords = [interpolate(at: t).coordinate]
        if idx < samples.count {
            coords.append(contentsOf: (idx..<samples.count).map { samples[$0].coordinate })
        }
        return coords
    }

    /// The comet trail: the last `window` *flight-seconds* behind the pilot,
    /// sliced into `sliceCount` fading segments. Tied to real seconds, so the
    /// tail length is independent of the playback-speed multiplier.
    func trailSlices(endingAt time: TimeInterval, window: TimeInterval, sliceCount: Int) -> [TrailSlice] {
        guard samples.count >= 2, timestep > 0, window > 0, sliceCount > 0 else { return [] }
        let end = min(max(time, 0), totalDuration)
        let start = max(0, end - window)
        guard end > start else { return [] }
        let sliceDur = (end - start) / Double(sliceCount)
        guard sliceDur > 0 else { return [] }

        var out: [TrailSlice] = []
        out.reserveCapacity(sliceCount)
        for k in 0..<sliceCount {
            let t0 = start + sliceDur * Double(k)
            let t1 = start + sliceDur * Double(k + 1)
            var coords: [CLLocationCoordinate2D] = [interpolate(at: t0).coordinate]
            let i0 = Int((t0 / timestep).rounded(.up))
            let i1 = Int((t1 / timestep).rounded(.down))
            if i1 >= i0, i0 < samples.count {
                for i in max(0, i0)...min(i1, samples.count - 1) { coords.append(samples[i].coordinate) }
            }
            coords.append(interpolate(at: t1).coordinate)
            guard coords.count >= 2 else { continue }
            let vario = interpolate(at: (t0 + t1) / 2).verticalSpeed ?? 0
            out.append(TrailSlice(id: k, coordinates: coords, meanVario: vario,
                                  ageFactor: Double(k + 1) / Double(sliceCount)))
        }
        return out
    }

    // MARK: - Resampling core

    private static func buildSamples(sorted: [GPSTrackPoint],
                                     offsets: [TimeInterval],
                                     timestep: TimeInterval) -> [ReplaySample] {
        let m = sorted.count
        if m == 0 { return [] }
        if m == 1 {
            let p = sorted[0]
            return [ReplaySample(time: 0,
                                 coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                                 altitude: p.altitude, speed: p.speed, verticalSpeed: nil, heading: 0)]
        }

        let duration = offsets[m - 1]
        // All-same-timestamp (or no grid): collapse to a single static frame.
        if duration <= 0 || timestep <= 0 {
            let p = sorted[0]
            let c0 = CLLocationCoordinate2D(latitude: sorted[0].latitude, longitude: sorted[0].longitude)
            let c1 = CLLocationCoordinate2D(latitude: sorted[m - 1].latitude, longitude: sorted[m - 1].longitude)
            return [ReplaySample(time: 0,
                                 coordinate: c0,
                                 altitude: p.altitude, speed: p.speed, verticalSpeed: nil,
                                 heading: bearing(from: c0, to: c1))]
        }

        let n = max(1, Int((duration / timestep).rounded()))
        let step = duration / Double(n)

        let lat = sorted.map { $0.latitude }
        let lon = sorted.map { $0.longitude }
        let hasAltitude = sorted.contains { $0.altitude != nil }
        let hasSpeed = sorted.contains { $0.speed != nil }
        let altFilled = fill(sorted.map { $0.altitude })
        let spdFilled = fill(sorted.map { $0.speed })

        let latT = tangents(offsets, lat)
        let lonT = tangents(offsets, lon)
        let altT = hasAltitude ? tangents(offsets, altFilled) : nil
        let spdT = hasSpeed ? tangents(offsets, spdFilled) : nil

        // Evaluate the splines on the uniform grid (advancing the segment
        // pointer, since query times are monotonically increasing).
        var coords: [CLLocationCoordinate2D] = []
        var alts: [Double?] = []
        var spds: [Double?] = []
        coords.reserveCapacity(n + 1)
        alts.reserveCapacity(n + 1)
        spds.reserveCapacity(n + 1)

        var seg = 0
        for k in 0...n {
            let tau = min(step * Double(k), duration)
            while seg < m - 2 && offsets[seg + 1] < tau { seg += 1 }
            let la = hermite(offsets, lat, latT, seg, tau)
            let lo = hermite(offsets, lon, lonT, seg, tau)
            coords.append(CLLocationCoordinate2D(latitude: la, longitude: lo))
            alts.append(hasAltitude ? hermite(offsets, altFilled, altT!, seg, tau) : nil)
            spds.append(hasSpeed ? hermite(offsets, spdFilled, spdT!, seg, tau) : nil)
        }

        let count = coords.count

        // Derive ground speed from the smoothed path when none was recorded.
        if !hasSpeed {
            for i in 0..<count {
                let hi = min(i + 1, count - 1)
                let lo = i > 0 ? i - 1 : i
                let d = distance(coords[lo], coords[hi])
                let dt = Double(hi - lo) * step
                spds[i] = dt > 0 ? d / dt : 0
            }
        }

        // Heading: look-ahead bearing (so slow thermalling doesn't jitter),
        // then unit-vector smoothing.
        let lookahead = max(1, Int((3.0 / step).rounded()))
        var rawHeading = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let j = min(i + lookahead, count - 1)
            if j == i {
                rawHeading[i] = i > 0 ? rawHeading[i - 1] : 0
                continue
            }
            let d = distance(coords[i], coords[j])
            if d < 0.5 {
                // Nearly stationary: hold the previous heading.
                rawHeading[i] = i > 0 ? rawHeading[i - 1] : bearing(from: coords[i], to: coords[j])
            } else {
                rawHeading[i] = bearing(from: coords[i], to: coords[j])
            }
        }
        let headingRadius = max(1, Int((2.0 / step).rounded()))
        let heading = smoothAngles(rawHeading, radius: headingRadius)

        // Vario: windowed central difference of the smoothed altitude.
        var vs = [Double?](repeating: nil, count: count)
        if hasAltitude {
            let w = max(1, Int((1.0 / step).rounded()))
            var raw = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let hi = min(i + w, count - 1)
                let lo = max(i - w, 0)
                let dt = Double(hi - lo) * step
                raw[i] = dt > 0 ? ((alts[hi] ?? 0) - (alts[lo] ?? 0)) / dt : 0
            }
            let smoothed = movingAverage(raw, radius: w)
            for i in 0..<count { vs[i] = smoothed[i] }
        }

        var result: [ReplaySample] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(ReplaySample(
                time: min(step * Double(i), duration),
                coordinate: coords[i],
                altitude: alts[i],
                speed: spds[i],
                verticalSpeed: vs[i],
                heading: heading[i]
            ))
        }
        return result
    }

    // MARK: - Vario runs (grouping)

    private static func buildRuns(_ samples: [ReplaySample]) -> [RunMeta] {
        guard samples.count >= 2 else { return [] }

        var varios = [Double](repeating: 0, count: samples.count)
        for i in 0..<samples.count { varios[i] = samples[i].verticalSpeed ?? 0 }
        let smoothed = movingAverage(varios, radius: 2)

        // Runs of consecutive samples sharing a 0.5-m/s bucket.
        var runs: [(bucket: Int, range: ClosedRange<Int>)] = []
        var start = 0
        var bucket = varioBucket(smoothed[0])
        for i in 1..<smoothed.count where varioBucket(smoothed[i]) != bucket {
            runs.append((bucket, start...(i - 1)))
            start = i
            bucket = varioBucket(smoothed[i])
        }
        runs.append((bucket, start...(smoothed.count - 1)))

        // Merge sub-3-sample runs into their neighbour so noisy tracks don't
        // explode into thousands of polylines.
        let minRun = 3
        var merged: [(bucket: Int, range: ClosedRange<Int>)] = []
        for run in runs {
            if let last = merged.last, run.range.count < minRun || last.bucket == run.bucket {
                merged[merged.count - 1] = (last.bucket, last.range.lowerBound...run.range.upperBound)
            } else {
                merged.append(run)
            }
        }
        if merged.count >= 2, merged[0].range.count < minRun {
            merged[1] = (merged[1].bucket, merged[0].range.lowerBound...merged[1].range.upperBound)
            merged.removeFirst()
        }

        return merged.map { run in
            let mean = smoothed[run.range].reduce(0, +) / Double(run.range.count)
            return RunMeta(range: run.range, meanVario: mean)
        }
    }

    private static func varioBucket(_ v: Double) -> Int {
        Int((min(max(v, -4), 4) * 2).rounded())   // 0.5 m/s buckets
    }

    private static func buildProfile(_ samples: [ReplaySample], duration: TimeInterval) -> [CGPoint] {
        guard duration > 0 else { return [] }
        let alts = samples.compactMap { $0.altitude }
        guard let minAlt = alts.min(), let maxAlt = alts.max() else { return [] }
        let span = max(maxAlt - minAlt, 1)

        // Downsample so the scrubber path stays light on very long flights.
        let target = 360
        let stride = max(1, samples.count / target)
        var out: [CGPoint] = []
        var i = 0
        while i < samples.count {
            if let a = samples[i].altitude {
                out.append(CGPoint(x: samples[i].time / duration, y: (a - minAlt) / span))
            }
            i += stride
        }
        if let last = samples.last, let a = last.altitude {
            out.append(CGPoint(x: last.time / duration, y: (a - minAlt) / span))
        }
        return out
    }

    // MARK: - Bounds

    private static func computeBounds(_ coords: [CLLocationCoordinate2D]) -> (CLLocationCoordinate2D, Double) {
        guard let first = coords.first else {
            return (CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1), 5000)
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let diag = CLLocation(latitude: minLat, longitude: minLon)
            .distance(from: CLLocation(latitude: maxLat, longitude: maxLon))
        let distance = min(max(diag * 1.6, 800), 400_000)
        return (center, distance)
    }

    // MARK: - Numeric helpers

    /// Fills `nil` gaps in an optional series by linear interpolation across
    /// known indices (nearest-carry at the ends). Returns zeros if all-nil —
    /// callers gate on `hasAltitude` / `hasSpeed` so those zeros are unused.
    private static func fill(_ arr: [Double?]) -> [Double] {
        let n = arr.count
        var out = [Double](repeating: 0, count: n)
        let known = arr.indices.filter { arr[$0] != nil }
        guard let firstKnown = known.first, let lastKnown = known.last else { return out }

        for i in 0..<firstKnown { out[i] = arr[firstKnown]! }
        for i in (lastKnown + 1)..<n { out[i] = arr[lastKnown]! }
        for k in known { out[k] = arr[k]! }
        for k in 0..<(known.count - 1) {
            let a = known[k], b = known[k + 1]
            if b > a + 1 {
                let va = arr[a]!, vb = arr[b]!
                for i in (a + 1)..<b {
                    let f = Double(i - a) / Double(b - a)
                    out[i] = va + (vb - va) * f
                }
            }
        }
        return out
    }

    /// Catmull-Rom tangents (finite differences over non-uniform time).
    private static func tangents(_ t: [TimeInterval], _ v: [Double]) -> [Double] {
        let n = v.count
        var m = [Double](repeating: 0, count: n)
        guard n >= 2 else { return m }
        for i in 0..<n {
            if i == 0 {
                let h = t[1] - t[0]; m[0] = h > 0 ? (v[1] - v[0]) / h : 0
            } else if i == n - 1 {
                let h = t[n - 1] - t[n - 2]; m[i] = h > 0 ? (v[n - 1] - v[n - 2]) / h : 0
            } else {
                let h = t[i + 1] - t[i - 1]; m[i] = h > 0 ? (v[i + 1] - v[i - 1]) / h : 0
            }
        }
        return m
    }

    /// Cubic Hermite evaluation on segment `seg` at time `tau`.
    private static func hermite(_ t: [TimeInterval], _ v: [Double], _ m: [Double],
                                _ seg: Int, _ tau: Double) -> Double {
        let i = seg
        let h = t[i + 1] - t[i]
        if h <= 0 { return v[i] }
        let s = min(max((tau - t[i]) / h, 0), 1)
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2
        return h00 * v[i] + h10 * h * m[i] + h01 * v[i + 1] + h11 * h * m[i + 1]
    }

    /// Centered moving average.
    private static func movingAverage(_ v: [Double], radius: Int) -> [Double] {
        let n = v.count
        guard n > 0, radius > 0 else { return v }
        return v.indices.map { i in
            let lo = max(0, i - radius), hi = min(n - 1, i + radius)
            return v[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    /// Wrap-safe angle smoothing: average unit vectors over a window, then take
    /// the argument. Avoids the 359°/1° discontinuity entirely.
    private static func smoothAngles(_ deg: [Double], radius: Int) -> [Double] {
        let n = deg.count
        guard n > 0 else { return [] }
        let cx = deg.map { cos($0 * .pi / 180) }
        let cy = deg.map { sin($0 * .pi / 180) }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius), hi = min(n - 1, i + radius)
            var sx = 0.0, sy = 0.0
            for j in lo...hi { sx += cx[j]; sy += cy[j] }
            let a = atan2(sy, sx) * 180 / .pi
            out[i] = (a + 360).truncatingRemainder(dividingBy: 360)
        }
        return out
    }

    private static func lerpOptional(_ a: Double?, _ b: Double?, _ f: Double) -> Double? {
        switch (a, b) {
        case let (x?, y?): return x + (y - x) * f
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    // MARK: - Angle / geo math (shared with the view)

    /// Signed shortest-arc difference `b - a`, in (-180, 180].
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    /// Interpolates between two angles along the shortest arc.
    static func lerpAngle(from: Double, to: Double, factor: Double) -> Double {
        let d = angleDelta(from, to)
        return (from + d * factor + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Initial great-circle bearing between two coordinates (degrees, 0 = north).
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
