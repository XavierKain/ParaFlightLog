//
//  ColoredGPSTraceMapView.swift
//  ParaFlightLog
//
//  Vue MapKit pour afficher une trace GPS colorée par vitesse
//  Target: iOS only
//

import SwiftUI
import MapKit

// MARK: - ColoredPolyline

/// Polyline personnalisée avec couleur
class ColoredPolyline: MKPolyline {
    var color: UIColor = .blue
}

// MARK: - ColoredGPSTraceMapView

struct ColoredGPSTraceMapView: UIViewRepresentable {
    let segments: [SpeedSegment]
    let showLegend: Bool

    init(segments: [SpeedSegment], showLegend: Bool = true) {
        self.segments = segments
        self.showLegend = showLegend
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Supprimer les overlays existants
        mapView.removeOverlays(mapView.overlays)

        guard !segments.isEmpty else { return }

        // Ajouter chaque segment comme overlay coloré
        for segment in segments {
            let coordinates = [
                CLLocationCoordinate2D(
                    latitude: segment.startPoint.latitude,
                    longitude: segment.startPoint.longitude
                ),
                CLLocationCoordinate2D(
                    latitude: segment.endPoint.latitude,
                    longitude: segment.endPoint.longitude
                )
            ]

            let polyline = ColoredPolyline(coordinates: coordinates, count: 2)
            polyline.color = UIColor(segment.color)
            mapView.addOverlay(polyline)
        }

        // Ajuster la région pour afficher toute la trace
        if let firstSegment = segments.first, let lastSegment = segments.last {
            // Calculer la région englobante
            var minLat = min(firstSegment.startPoint.latitude, lastSegment.endPoint.latitude)
            var maxLat = max(firstSegment.startPoint.latitude, lastSegment.endPoint.latitude)
            var minLon = min(firstSegment.startPoint.longitude, lastSegment.endPoint.longitude)
            var maxLon = max(firstSegment.startPoint.longitude, lastSegment.endPoint.longitude)

            // Parcourir tous les segments pour trouver les vraies limites
            for segment in segments {
                minLat = min(minLat, segment.startPoint.latitude, segment.endPoint.latitude)
                maxLat = max(maxLat, segment.startPoint.latitude, segment.endPoint.latitude)
                minLon = min(minLon, segment.startPoint.longitude, segment.endPoint.longitude)
                maxLon = max(maxLon, segment.startPoint.longitude, segment.endPoint.longitude)
            }

            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            )

            let span = MKCoordinateSpan(
                latitudeDelta: (maxLat - minLat) * 1.2,  // 20% de marge
                longitudeDelta: (maxLon - minLon) * 1.2
            )

            let region = MKCoordinateRegion(center: center, span: span)
            mapView.setRegion(region, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? ColoredPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.color
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - SpeedLegendView

/// Légende des couleurs de vitesse avec barre de gradient et marqueurs intermédiaires
struct SpeedLegendView: View {
    var body: some View {
        VStack(spacing: 4) {
            // Labels de vitesse au-dessus du gradient
            HStack {
                Text("0")
                Spacer()
                Text("15")
                Spacer()
                Text("30")
                Spacer()
                Text("45")
                Spacer()
                Text("60+")
            }
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)

            // Barre de gradient avec marqueurs
            ZStack(alignment: .top) {
                // Gradient principal
                LinearGradient(
                    colors: GPSTraceColorMapper.getGradientColors(),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 10)
                .clipShape(Capsule())

                // Points de marquage
                HStack {
                    Circle()
                        .fill(GPSTraceColorMapper.colorForSpeed(0))
                        .frame(width: 8, height: 8)
                    Spacer()
                    Circle()
                        .fill(GPSTraceColorMapper.colorForSpeed(15))
                        .frame(width: 8, height: 8)
                    Spacer()
                    Circle()
                        .fill(GPSTraceColorMapper.colorForSpeed(30))
                        .frame(width: 8, height: 8)
                    Spacer()
                    Circle()
                        .fill(GPSTraceColorMapper.colorForSpeed(45))
                        .frame(width: 8, height: 8)
                    Spacer()
                    Circle()
                        .fill(GPSTraceColorMapper.colorForSpeed(60))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 1)
                .offset(y: 1)
            }

            // Texte "km/h" en dessous
            Text("km/h")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 200)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground).opacity(0.9))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }
}
