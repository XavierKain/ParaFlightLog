//
//  SoarXGlyph.swift
//  ParaFlightLogWidgetExtension
//
//  The paraglider mark, drawn rather than rasterized.
//
//  Target: Widget Extension (iOS + watchOS)
//

import SwiftUI

/// A paraglider seen from the side: crescent canopy, risers, pilot.
///
/// Drawn as a vector instead of shipped as a PNG for three reasons a watch
/// complication makes unforgiving:
///
///  * **Tinting.** The system renders complications in accented, vibrant or
///    full-colour mode depending on the watch face. A colour raster is
///    desaturated into a grey smudge; a filled path picks up the face's tint.
///  * **Size.** One path serves the 41 mm circular corner and the 49 mm Ultra
///    rectangular slot without a resampling blur.
///  * **Framing.** The old asset was a square crop of the app icon squeezed
///    into a circle, which sliced the wordmark across the bottom edge. A shape
///    laid out in its own unit square cannot be cut off by its container.
///
/// Geometry is expressed in a unit square and scaled to the shortest side, so
/// the mark stays centred and keeps its proportions in any frame.
struct SoarXGlyph: View {
    /// Line weight relative to the glyph's size — risers thin out gracefully
    /// but never fall below a pixel on the smallest complication.
    private let riserWidth: CGFloat = 0.018

    /// The drawn ink spans y 0.12 to 0.935 of the unit square, so its midpoint
    /// sits below the square's. Left uncorrected the mark hangs high in a
    /// circular complication, which reads as a misalignment rather than as a
    /// glider with air beneath it. Lifting by the difference centres the ink
    /// itself, which is what the eye measures.
    private let inkOffsetY: CGFloat = 0.5 - (0.12 + 0.935) / 2

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height)
            let originX = (size.width - scale) / 2
            let originY = (size.height - scale) / 2
            let offsetY = inkOffsetY
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: originX + x * scale, y: originY + (y + offsetY) * scale)
            }

            context.fill(Self.canopy(point), with: .style(.primary))
            context.stroke(
                Self.risers(point),
                with: .style(.primary),
                style: StrokeStyle(lineWidth: riserWidth * scale, lineCap: .round)
            )
            context.fill(Self.pilot(point), with: .style(.primary))
        }
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    /// The canopy: two arcs sharing their tips, so the wing reads as a crescent
    /// with the camber of an inflated glider rather than a flat banana.
    ///
    /// Span-to-depth is held near 6:1 and the tips hang below the centre. A
    /// rounder dome over a wide fan of lines reads as a parachute instead —
    /// what separates the two silhouettes is the aspect ratio, not the detail.
    private static func canopy(_ p: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var path = Path()
        path.move(to: p(0.03, 0.40))
        path.addQuadCurve(to: p(0.97, 0.40), control: p(0.50, 0.12))
        path.addQuadCurve(to: p(0.03, 0.40), control: p(0.50, 0.33))
        path.closeSubpath()
        return path
    }

    /// Four risers fanning from the canopy's trailing edge to the pilot.
    ///
    /// The anchors are points sampled off the canopy's lower curve, so the
    /// lines meet the wing exactly rather than floating under it.
    private static func risers(_ p: (CGFloat, CGFloat) -> CGPoint) -> Path {
        let hang = p(0.50, 0.825)
        var path = Path()
        for anchor in [(0.735, 0.374), (0.594, 0.366), (0.406, 0.366), (0.265, 0.374)] {
            path.move(to: p(anchor.0, anchor.1))
            path.addLine(to: hang)
        }
        return path
    }

    /// The pilot, a single mass — at complication size a harness and a body
    /// resolve into one blob anyway, so draw the blob deliberately.
    private static func pilot(_ p: (CGFloat, CGFloat) -> CGPoint) -> Path {
        let centre = p(0.50, 0.885)
        let radius = p(0.55, 0.885).x - centre.x
        return Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
}

#Preview {
    HStack(spacing: 16) {
        SoarXGlyph().frame(width: 24, height: 24)
        SoarXGlyph().frame(width: 48, height: 48)
        SoarXGlyph().frame(width: 96, height: 96)
    }
    .padding()
}
