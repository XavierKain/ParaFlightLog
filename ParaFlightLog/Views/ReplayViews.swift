//
//  ReplayViews.swift
//  ParaFlightLog
//
//  Reusable UI pieces for the 3D flight replay:
//    - `VarioPalette`: the continuous variometer color gradient (kept out of
//      `ReplayEngine` so the engine stays UI-free / testable).
//    - `AltitudeProfileScrubber`: the timeline drawn as the flight's altitude
//      curve, with a generous touch target and a draggable playhead knob.
//
//  Target: iOS only
//

import SwiftUI

// MARK: - Vario color palette

/// Maps vertical speed (m/s) to a variometer color. Piecewise-linear RGB
/// between fixed stops: strong sink → red, sink → orange, neutral → cyan,
/// climb → light green, strong climb → green.
nonisolated enum VarioPalette {
    private static let stops: [(v: Double, r: Double, g: Double, b: Double)] = [
        (-4.0, 0.95, 0.15, 0.15),
        (-1.5, 1.00, 0.55, 0.10),
        ( 0.0, 0.25, 0.80, 0.95),
        ( 1.5, 0.55, 0.90, 0.30),
        ( 4.0, 0.10, 0.85, 0.25)
    ]

    static func color(_ verticalSpeed: Double) -> Color {
        let v = min(max(verticalSpeed, stops.first!.v), stops.last!.v)
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if v <= b.v {
                let f = b.v > a.v ? (v - a.v) / (b.v - a.v) : 0
                return Color(red: a.r + (b.r - a.r) * f,
                             green: a.g + (b.g - a.g) * f,
                             blue: a.b + (b.b - a.b) * f)
            }
        }
        let last = stops.last!
        return Color(red: last.r, green: last.g, blue: last.b)
    }
}

// MARK: - AltitudeProfileScrubber

/// Timeline scrubber drawn as the flight's altitude profile: the flown part is
/// filled, a playhead knob marks the current position, and dragging scrubs
/// time. The drawing sits in a shorter band while the whole control keeps a
/// tall, finger-friendly hit area.
struct AltitudeProfileScrubber: View {
    /// Normalised altitude curve (x = time 0…1, y = altitude 0…1).
    let profile: [CGPoint]
    /// Current playback progress, 0…1.
    let progress: Double
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void

    /// Height of the drawn curve band inside the taller touch area.
    private let bandHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let bandTop = (size.height - bandHeight) / 2
            let clampedProgress = min(max(progress, 0), 1)
            let playheadX = size.width * clampedProgress

            ZStack(alignment: .topLeading) {
                // The curve band, vertically centered.
                ZStack(alignment: .leading) {
                    profilePath(in: CGSize(width: size.width, height: bandHeight), closed: true)
                        .fill(Color.white.opacity(0.12))
                    profilePath(in: CGSize(width: size.width, height: bandHeight), closed: false)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1.5)

                    profilePath(in: CGSize(width: size.width, height: bandHeight), closed: true)
                        .fill(Color.blue.opacity(0.45))
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: playheadX)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                }
                .frame(height: bandHeight)
                .offset(y: bandTop)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Playhead line spanning the whole height, with a knob.
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: size.height)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .offset(x: playheadX - 1)

                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: playheadX - 8, y: bandTop + bandHeight / 2 - 8)
            }
            .contentShape(Rectangle())   // full band is draggable
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / size.width, 0), 1)
                        onScrub(fraction)
                    }
                    .onEnded { _ in onScrubEnd() }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Flight timeline")
        .accessibilityHint("Drag to move through the flight")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }

    /// Altitude curve path; `closed` adds the baseline for a fillable area.
    private func profilePath(in size: CGSize, closed: Bool) -> Path {
        Path { path in
            guard profile.count >= 2 else {
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                if closed {
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                return
            }

            // Headroom so peaks don't touch the edge.
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * size.width,
                        y: size.height - (p.y * (size.height - 10) + 5))
            }

            path.move(to: point(profile[0]))
            for p in profile.dropFirst() { path.addLine(to: point(p)) }
            if closed {
                path.addLine(to: CGPoint(x: profile.last.map { $0.x * size.width } ?? size.width, y: size.height))
                path.addLine(to: CGPoint(x: profile.first.map { $0.x * size.width } ?? 0, y: size.height))
                path.closeSubpath()
            }
        }
    }
}
