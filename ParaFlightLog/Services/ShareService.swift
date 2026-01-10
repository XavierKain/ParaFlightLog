//
//  ShareService.swift
//  ParaFlightLog
//
//  Service de partage social
//  Génère des images de partage pour vols et badges
//  Gère les deep links et le partage vers les réseaux sociaux
//  Target: iOS only
//

import Foundation
import SwiftUI
import UIKit
import MapKit

// MARK: - Share Models

/// Type de contenu à partager
enum ShareContentType {
    case flight(PublicFlight)
    case localFlight(Flight)
    case badge(Badge, Date)
    case achievement(String, String, String)  // title, description, icon
}

/// Configuration de l'image de partage
struct ShareImageConfig: Sendable {
    let width: CGFloat
    let height: CGFloat
    let backgroundColor: UIColor
    let accentColor: UIColor
    let includeAppBranding: Bool

    // Presets using standard colors (not dynamic system colors)
    static let instagram = ShareImageConfig(
        width: 1080,
        height: 1920,
        backgroundColor: UIColor.white,
        accentColor: UIColor.systemBlue,
        includeAppBranding: true
    )

    static let square = ShareImageConfig(
        width: 1080,
        height: 1080,
        backgroundColor: UIColor.white,
        accentColor: UIColor.systemBlue,
        includeAppBranding: true
    )

    static let standard = ShareImageConfig(
        width: 1200,
        height: 630,
        backgroundColor: UIColor.white,
        accentColor: UIColor.systemBlue,
        includeAppBranding: true
    )
}

// MARK: - ShareService

@Observable
@MainActor
final class ShareService {
    static let shared = ShareService()

    // MARK: - Properties

    /// État de génération
    private(set) var isGenerating = false

    /// Scheme de l'app pour les deep links
    private let appScheme = "paraflightlog"

    /// URL du site web (pour le partage)
    private let websiteURL = "https://paraflightlog.app"

    private init() {}

    // MARK: - Deep Links

    /// Génère un deep link pour un vol
    func getDeepLink(for flightId: String) -> URL {
        URL(string: "\(appScheme)://flight/\(flightId)") ?? URL(string: websiteURL)!
    }

    /// Génère un deep link pour un badge
    func getDeepLink(for badgeId: String, isBadge: Bool = true) -> URL {
        URL(string: "\(appScheme)://badge/\(badgeId)") ?? URL(string: websiteURL)!
    }

    /// Génère un deep link pour un profil pilote
    func getDeepLink(forPilot pilotId: String) -> URL {
        URL(string: "\(appScheme)://pilot/\(pilotId)") ?? URL(string: websiteURL)!
    }

    /// Génère un lien web partageable
    func getWebLink(for flightId: String) -> URL {
        URL(string: "\(websiteURL)/flight/\(flightId)") ?? URL(string: websiteURL)!
    }

    // MARK: - Flight Share Image Generation

    /// Génère une image de partage pour un vol public
    func generateFlightShareImage(
        flight: PublicFlight,
        config: ShareImageConfig
    ) -> UIImage {
        isGenerating = true
        defer { isGenerating = false }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: config.width, height: config.height))

        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: config.width, height: config.height)

            // Background gradient
            drawGradientBackground(in: context, rect: rect, config: config)

            // Content
            drawFlightContent(flight: flight, in: context, rect: rect, config: config)

            // App branding
            if config.includeAppBranding {
                drawAppBranding(in: context, rect: rect, config: config)
            }
        }
    }

    // MARK: - Local Flight Share Image Generation

    /// Génère une image de partage pour un vol local avec carte GPS
    func generateLocalFlightShareImage(
        flight: Flight,
        mapSnapshot: UIImage?,
        config: ShareImageConfig
    ) -> UIImage {
        isGenerating = true
        defer { isGenerating = false }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: config.width, height: config.height))

        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: config.width, height: config.height)

            // Background gradient
            drawGradientBackground(in: context, rect: rect, config: config)

            // Map snapshot (si disponible)
            if let mapImage = mapSnapshot {
                drawMapSnapshot(mapImage, in: context, rect: rect, config: config)
            }

            // Content avec nouveau design
            drawLocalFlightContent(flight: flight, hasMap: mapSnapshot != nil, in: context, rect: rect, config: config)

            // App branding
            if config.includeAppBranding {
                drawAppBranding(in: context, rect: rect, config: config)
            }
        }
    }

    /// Génère un snapshot de la carte avec trace GPS colorée
    func generateMapSnapshot(
        for flight: Flight,
        size: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let track = flight.gpsTrack, track.count >= 2 else {
            completion(nil)
            return
        }

        // Calculer la région
        let lats = track.map { $0.latitude }
        let lons = track.map { $0.longitude }
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max(0.01, (maxLat - minLat) * 1.4)
        let spanLon = max(0.01, (maxLon - minLon) * 1.4)

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.mapType = .hybrid
        options.showsBuildings = false

        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { snapshot, error in
            guard let snapshot = snapshot, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Dessiner la trace GPS colorée sur le snapshot
            UIGraphicsBeginImageContextWithOptions(snapshot.image.size, true, snapshot.image.scale)
            snapshot.image.draw(at: .zero)

            guard let context = UIGraphicsGetCurrentContext() else {
                DispatchQueue.main.async { completion(snapshot.image) }
                return
            }

            // Générer les segments colorés
            let segments = GPSTraceColorMapper.generateColoredSegments(points: track)

            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(4.0)

            for segment in segments {
                let startPoint = snapshot.point(for: CLLocationCoordinate2D(
                    latitude: segment.startPoint.latitude,
                    longitude: segment.startPoint.longitude
                ))
                let endPoint = snapshot.point(for: CLLocationCoordinate2D(
                    latitude: segment.endPoint.latitude,
                    longitude: segment.endPoint.longitude
                ))

                context.setStrokeColor(UIColor(segment.color).cgColor)
                context.move(to: startPoint)
                context.addLine(to: endPoint)
                context.strokePath()
            }

            // Markers départ/arrivée
            if let first = track.first {
                let startPoint = snapshot.point(for: CLLocationCoordinate2D(
                    latitude: first.latitude, longitude: first.longitude
                ))
                self.drawMarker(at: startPoint, color: .systemGreen, in: context)
            }

            if let last = track.last {
                let endPoint = snapshot.point(for: CLLocationCoordinate2D(
                    latitude: last.latitude, longitude: last.longitude
                ))
                self.drawMarker(at: endPoint, color: .systemRed, in: context)
            }

            let finalImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            DispatchQueue.main.async { completion(finalImage) }
        }
    }

    private func drawMarker(at point: CGPoint, color: UIColor, in context: CGContext) {
        let markerSize: CGFloat = 16
        let rect = CGRect(
            x: point.x - markerSize / 2,
            y: point.y - markerSize / 2,
            width: markerSize,
            height: markerSize
        )

        // Cercle extérieur blanc
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: rect.insetBy(dx: -2, dy: -2))

        // Cercle intérieur coloré
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
    }

    // MARK: - Badge Share Image Generation

    /// Génère une image de partage pour un badge obtenu
    func generateBadgeShareImage(
        badge: Badge,
        earnedAt: Date,
        config: ShareImageConfig
    ) -> UIImage {
        isGenerating = true
        defer { isGenerating = false }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: config.width, height: config.height))

        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: config.width, height: config.height)

            // Background with tier color
            drawBadgeBackground(badge: badge, in: context, rect: rect)

            // Badge content
            drawBadgeContent(badge: badge, earnedAt: earnedAt, in: context, rect: rect, config: config)

            // App branding
            if config.includeAppBranding {
                drawAppBranding(in: context, rect: rect, config: config)
            }
        }
    }

    // MARK: - Share Text Generation

    /// Génère le texte de partage pour un vol
    func generateFlightShareText(flight: PublicFlight) -> String {
        var text = "Vol de \(flight.formattedDuration)"

        if let spotName = flight.spotName {
            text += " @ \(spotName)"
        }

        text += "\n\n"

        if let altitude = flight.maxAltitude {
            text += "Alt. max: \(Int(altitude))m\n"
        }

        if let distance = flight.totalDistance {
            if distance >= 1000 {
                text += "Distance: \(String(format: "%.1f", distance / 1000))km\n"
            } else {
                text += "Distance: \(Int(distance))m\n"
            }
        }

        text += "\n#Parapente #Paragliding #SoarX"

        return text
    }

    /// Génère le texte de partage pour un badge
    func generateBadgeShareText(badge: Badge) -> String {
        var text = "Badge obtenu: \(badge.localizedName)!\n\n"
        text += badge.localizedDescription
        text += "\n\n+\(badge.xpReward) XP"
        text += "\n\n#Parapente #Paragliding #SoarX #\(badge.tier.displayName)"

        return text
    }

    // MARK: - Private Drawing Methods

    private func drawGradientBackground(in context: UIGraphicsImageRendererContext, rect: CGRect, config: ShareImageConfig) {
        let cgContext = context.cgContext

        let colors = [
            UIColor(red: 0.05, green: 0.10, blue: 0.20, alpha: 1.0).cgColor,
            UIColor(red: 0.10, green: 0.20, blue: 0.35, alpha: 1.0).cgColor
        ]

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let locations: [CGFloat] = [0.0, 1.0]

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: rect.height),
                options: []
            )
        }
    }

    private func drawBadgeBackground(badge: Badge, in context: UIGraphicsImageRendererContext, rect: CGRect) {
        let cgContext = context.cgContext

        // Couleur basée sur le tier
        let tierColor: UIColor
        switch badge.tier {
        case .bronze:
            tierColor = UIColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1.0)
        case .silver:
            tierColor = UIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)
        case .gold:
            tierColor = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        case .platinum:
            tierColor = UIColor(red: 0.9, green: 0.89, blue: 0.88, alpha: 1.0)
        }

        let colors = [
            UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1.0).cgColor,
            tierColor.withAlphaComponent(0.3).cgColor
        ]

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let locations: [CGFloat] = [0.0, 1.0]

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: rect.width, y: rect.height),
                options: []
            )
        }
    }

    private func drawFlightContent(flight: PublicFlight, in context: UIGraphicsImageRendererContext, rect: CGRect, config: ShareImageConfig) {
        let padding: CGFloat = 60
        _ = rect.width - (padding * 2)  // contentWidth reserved for future use

        // Titre "VOL PARAPENTE"
        let titleFont = UIFont.systemFont(ofSize: 48, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.6)
        ]
        let titleText = "VOL PARAPENTE"
        let titleSize = titleText.size(withAttributes: titleAttrs)
        let titleRect = CGRect(
            x: (rect.width - titleSize.width) / 2,
            y: rect.height * 0.12,
            width: titleSize.width,
            height: titleSize.height
        )
        titleText.draw(in: titleRect, withAttributes: titleAttrs)

        // Durée en grand
        let durationFont = UIFont.systemFont(ofSize: 120, weight: .bold)
        let durationAttrs: [NSAttributedString.Key: Any] = [
            .font: durationFont,
            .foregroundColor: UIColor.white
        ]
        let durationText = flight.formattedDuration
        let durationSize = durationText.size(withAttributes: durationAttrs)
        let durationRect = CGRect(
            x: (rect.width - durationSize.width) / 2,
            y: rect.height * 0.25,
            width: durationSize.width,
            height: durationSize.height
        )
        durationText.draw(in: durationRect, withAttributes: durationAttrs)

        // Spot
        if let spotName = flight.spotName {
            let spotFont = UIFont.systemFont(ofSize: 40, weight: .medium)
            let spotAttrs: [NSAttributedString.Key: Any] = [
                .font: spotFont,
                .foregroundColor: UIColor.systemBlue
            ]
            let spotSize = spotName.size(withAttributes: spotAttrs)
            let spotRect = CGRect(
                x: (rect.width - spotSize.width) / 2,
                y: durationRect.maxY + 30,
                width: spotSize.width,
                height: spotSize.height
            )
            spotName.draw(in: spotRect, withAttributes: spotAttrs)
        }

        // Stats
        var statsY = rect.height * 0.50
        let statSpacing: CGFloat = 80

        let statFont = UIFont.systemFont(ofSize: 36, weight: .semibold)
        let statValueFont = UIFont.systemFont(ofSize: 56, weight: .bold)
        let statLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: statFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.7)
        ]
        let statValueAttrs: [NSAttributedString.Key: Any] = [
            .font: statValueFont,
            .foregroundColor: UIColor.white
        ]

        if let altitude = flight.maxAltitude {
            drawStatCard(
                label: "ALTITUDE MAX",
                value: "\(Int(altitude)) m",
                at: CGPoint(x: rect.width / 2, y: statsY),
                labelAttrs: statLabelAttrs,
                valueAttrs: statValueAttrs
            )
            statsY += statSpacing
        }

        if let distance = flight.totalDistance {
            let distanceStr = distance >= 1000
                ? String(format: "%.1f km", distance / 1000)
                : "\(Int(distance)) m"
            drawStatCard(
                label: "DISTANCE",
                value: distanceStr,
                at: CGPoint(x: rect.width / 2, y: statsY),
                labelAttrs: statLabelAttrs,
                valueAttrs: statValueAttrs
            )
            statsY += statSpacing
        }

        if let speed = flight.maxSpeed {
            drawStatCard(
                label: "VITESSE MAX",
                value: "\(Int(speed * 3.6)) km/h",
                at: CGPoint(x: rect.width / 2, y: statsY),
                labelAttrs: statLabelAttrs,
                valueAttrs: statValueAttrs
            )
        }

        // Date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.locale = Locale(identifier: "fr_FR")
        let dateStr = dateFormatter.string(from: flight.startDate)

        let dateFont = UIFont.systemFont(ofSize: 32, weight: .regular)
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: dateFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.6)
        ]
        let dateSize = dateStr.size(withAttributes: dateAttrs)
        let dateRect = CGRect(
            x: (rect.width - dateSize.width) / 2,
            y: rect.height * 0.82,
            width: dateSize.width,
            height: dateSize.height
        )
        dateStr.draw(in: dateRect, withAttributes: dateAttrs)

        // Pilote
        let pilotFont = UIFont.systemFont(ofSize: 36, weight: .medium)
        let pilotAttrs: [NSAttributedString.Key: Any] = [
            .font: pilotFont,
            .foregroundColor: UIColor.white
        ]
        let pilotText = flight.pilotName
        let pilotSize = pilotText.size(withAttributes: pilotAttrs)
        let pilotRect = CGRect(
            x: (rect.width - pilotSize.width) / 2,
            y: dateRect.maxY + 15,
            width: pilotSize.width,
            height: pilotSize.height
        )
        pilotText.draw(in: pilotRect, withAttributes: pilotAttrs)
    }

    private func drawStatCard(label: String, value: String, at point: CGPoint, labelAttrs: [NSAttributedString.Key: Any], valueAttrs: [NSAttributedString.Key: Any]) {
        let labelSize = label.size(withAttributes: labelAttrs)
        let valueSize = value.size(withAttributes: valueAttrs)

        let labelRect = CGRect(
            x: point.x - labelSize.width / 2,
            y: point.y,
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(in: labelRect, withAttributes: labelAttrs)

        let valueRect = CGRect(
            x: point.x - valueSize.width / 2,
            y: labelRect.maxY + 8,
            width: valueSize.width,
            height: valueSize.height
        )
        value.draw(in: valueRect, withAttributes: valueAttrs)
    }

    private func drawBadgeContent(badge: Badge, earnedAt: Date, in context: UIGraphicsImageRendererContext, rect: CGRect, config: ShareImageConfig) {
        // Titre "BADGE OBTENU"
        let titleFont = UIFont.systemFont(ofSize: 44, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.8)
        ]
        let titleText = "BADGE OBTENU"
        let titleSize = titleText.size(withAttributes: titleAttrs)
        let titleRect = CGRect(
            x: (rect.width - titleSize.width) / 2,
            y: rect.height * 0.15,
            width: titleSize.width,
            height: titleSize.height
        )
        titleText.draw(in: titleRect, withAttributes: titleAttrs)

        // Icône du badge (cercle avec symbole)
        let iconSize: CGFloat = 200
        let iconRect = CGRect(
            x: (rect.width - iconSize) / 2,
            y: rect.height * 0.28,
            width: iconSize,
            height: iconSize
        )

        // Couleur du tier
        let tierColor: UIColor
        switch badge.tier {
        case .bronze:
            tierColor = UIColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1.0)
        case .silver:
            tierColor = UIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)
        case .gold:
            tierColor = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        case .platinum:
            tierColor = UIColor(red: 0.9, green: 0.89, blue: 0.88, alpha: 1.0)
        }

        // Dessiner le cercle
        let cgContext = context.cgContext
        cgContext.setFillColor(tierColor.withAlphaComponent(0.3).cgColor)
        cgContext.fillEllipse(in: iconRect)
        cgContext.setStrokeColor(tierColor.cgColor)
        cgContext.setLineWidth(4)
        cgContext.strokeEllipse(in: iconRect.insetBy(dx: 2, dy: 2))

        // Dessiner le symbole SF Symbol au centre
        if let symbolImage = UIImage(systemName: badge.icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 80, weight: .medium))
            .withTintColor(tierColor, renderingMode: .alwaysOriginal) {
            let symbolSize = symbolImage.size
            let symbolRect = CGRect(
                x: iconRect.midX - symbolSize.width / 2,
                y: iconRect.midY - symbolSize.height / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )
            symbolImage.draw(in: symbolRect)
        }

        // Nom du badge
        let nameFont = UIFont.systemFont(ofSize: 52, weight: .bold)
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: UIColor.white
        ]
        let nameText = badge.localizedName
        let nameSize = nameText.size(withAttributes: nameAttrs)
        let nameRect = CGRect(
            x: (rect.width - nameSize.width) / 2,
            y: iconRect.maxY + 40,
            width: nameSize.width,
            height: nameSize.height
        )
        nameText.draw(in: nameRect, withAttributes: nameAttrs)

        // Tier
        let tierFont = UIFont.systemFont(ofSize: 36, weight: .semibold)
        let tierAttrs: [NSAttributedString.Key: Any] = [
            .font: tierFont,
            .foregroundColor: tierColor
        ]
        let tierText = badge.tier.displayName.uppercased()
        let tierSize = tierText.size(withAttributes: tierAttrs)
        let tierRect = CGRect(
            x: (rect.width - tierSize.width) / 2,
            y: nameRect.maxY + 15,
            width: tierSize.width,
            height: tierSize.height
        )
        tierText.draw(in: tierRect, withAttributes: tierAttrs)

        // Description
        let descFont = UIFont.systemFont(ofSize: 28, weight: .regular)
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: descFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.7)
        ]
        let descText = badge.localizedDescription
        let descParagraphStyle = NSMutableParagraphStyle()
        descParagraphStyle.alignment = .center
        var descAttrsWithPara = descAttrs
        descAttrsWithPara[.paragraphStyle] = descParagraphStyle

        let maxDescWidth = rect.width - 120
        let descRect = CGRect(
            x: (rect.width - maxDescWidth) / 2,
            y: tierRect.maxY + 30,
            width: maxDescWidth,
            height: 100
        )
        descText.draw(in: descRect, withAttributes: descAttrsWithPara)

        // XP gagné
        let xpFont = UIFont.systemFont(ofSize: 48, weight: .bold)
        let xpAttrs: [NSAttributedString.Key: Any] = [
            .font: xpFont,
            .foregroundColor: UIColor.systemYellow
        ]
        let xpText = "+\(badge.xpReward) XP"
        let xpSize = xpText.size(withAttributes: xpAttrs)
        let xpRect = CGRect(
            x: (rect.width - xpSize.width) / 2,
            y: rect.height * 0.78,
            width: xpSize.width,
            height: xpSize.height
        )
        xpText.draw(in: xpRect, withAttributes: xpAttrs)

        // Date d'obtention
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.locale = Locale(identifier: "fr_FR")
        let dateStr = dateFormatter.string(from: earnedAt)

        let dateFont = UIFont.systemFont(ofSize: 24, weight: .regular)
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: dateFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.5)
        ]
        let dateSize = dateStr.size(withAttributes: dateAttrs)
        let dateRect = CGRect(
            x: (rect.width - dateSize.width) / 2,
            y: xpRect.maxY + 20,
            width: dateSize.width,
            height: dateSize.height
        )
        dateStr.draw(in: dateRect, withAttributes: dateAttrs)
    }

    private func drawAppBranding(in context: UIGraphicsImageRendererContext, rect: CGRect, config: ShareImageConfig) {
        let brandingFont = UIFont.systemFont(ofSize: 28, weight: .medium)
        let brandingAttrs: [NSAttributedString.Key: Any] = [
            .font: brandingFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.4)
        ]
        let brandingText = "SoarX"
        let brandingSize = brandingText.size(withAttributes: brandingAttrs)
        let brandingRect = CGRect(
            x: (rect.width - brandingSize.width) / 2,
            y: rect.height - brandingSize.height - 40,
            width: brandingSize.width,
            height: brandingSize.height
        )
        brandingText.draw(in: brandingRect, withAttributes: brandingAttrs)
    }

    // MARK: - Map Snapshot Drawing

    private func drawMapSnapshot(_ mapImage: UIImage, in context: UIGraphicsImageRendererContext, rect: CGRect, config: ShareImageConfig) {
        let mapHeight = rect.height * 0.40
        let mapPadding: CGFloat = 40
        let mapWidth = rect.width - (mapPadding * 2)

        let mapRect = CGRect(
            x: mapPadding,
            y: rect.height * 0.08,
            width: mapWidth,
            height: mapHeight
        )

        // Dessiner l'ombre
        let cgContext = context.cgContext
        cgContext.saveGState()
        cgContext.setShadow(offset: CGSize(width: 0, height: 8), blur: 20, color: UIColor.black.withAlphaComponent(0.4).cgColor)

        // Dessiner le cadre arrondi
        let path = UIBezierPath(roundedRect: mapRect, cornerRadius: 20)
        cgContext.addPath(path.cgPath)
        cgContext.clip()

        // Dessiner l'image de la carte
        mapImage.draw(in: mapRect)

        cgContext.restoreGState()

        // Bordure subtile
        UIColor.white.withAlphaComponent(0.3).setStroke()
        let borderPath = UIBezierPath(roundedRect: mapRect, cornerRadius: 20)
        borderPath.lineWidth = 2
        borderPath.stroke()
    }

    // MARK: - Local Flight Content Drawing (Nouveau design)

    private func drawLocalFlightContent(flight: Flight, hasMap: Bool, in context: UIGraphicsImageRendererContext, rect: CGRect, config: ShareImageConfig) {
        let padding: CGFloat = 50

        // Position de départ du contenu (après la carte si présente)
        let contentStartY = hasMap ? rect.height * 0.52 : rect.height * 0.15

        // Titre "VOL PARAPENTE" en haut
        let titleFont = UIFont.systemFont(ofSize: 36, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.5)
        ]
        let titleText = "VOL PARAPENTE"
        let titleSize = titleText.size(withAttributes: titleAttrs)
        let titleY = hasMap ? rect.height * 0.03 : rect.height * 0.08
        let titleRect = CGRect(
            x: (rect.width - titleSize.width) / 2,
            y: titleY,
            width: titleSize.width,
            height: titleSize.height
        )
        titleText.draw(in: titleRect, withAttributes: titleAttrs)

        // Durée en grand (centré)
        let durationFont = UIFont.systemFont(ofSize: 100, weight: .bold)
        let durationAttrs: [NSAttributedString.Key: Any] = [
            .font: durationFont,
            .foregroundColor: UIColor.white
        ]
        let durationText = flight.durationFormatted
        let durationSize = durationText.size(withAttributes: durationAttrs)
        let durationRect = CGRect(
            x: (rect.width - durationSize.width) / 2,
            y: contentStartY,
            width: durationSize.width,
            height: durationSize.height
        )
        durationText.draw(in: durationRect, withAttributes: durationAttrs)

        // Spot (si disponible)
        var nextY = durationRect.maxY + 15
        if let spotName = flight.spotName, !spotName.isEmpty {
            let spotFont = UIFont.systemFont(ofSize: 36, weight: .medium)
            let spotAttrs: [NSAttributedString.Key: Any] = [
                .font: spotFont,
                .foregroundColor: UIColor.systemBlue
            ]
            let spotSize = spotName.size(withAttributes: spotAttrs)
            let spotRect = CGRect(
                x: (rect.width - spotSize.width) / 2,
                y: nextY,
                width: spotSize.width,
                height: spotSize.height
            )
            spotName.draw(in: spotRect, withAttributes: spotAttrs)
            nextY = spotRect.maxY + 30
        } else {
            nextY += 20
        }

        // Stats en grille 2x2 (nouveau layout)
        let statsY = nextY + 10
        let cardWidth = (rect.width - padding * 3) / 2
        let cardHeight: CGFloat = 90

        var stats: [(label: String, value: String, icon: String)] = []

        if let altitude = flight.maxAltitude {
            stats.append(("ALT. MAX", "\(Int(altitude)) m", "arrow.up"))
        }
        if let distance = flight.totalDistance {
            let distStr = distance >= 1000 ? String(format: "%.1f km", distance / 1000) : "\(Int(distance)) m"
            stats.append(("DISTANCE", distStr, "point.topleft.down.to.point.bottomright.curvepath"))
        }
        if let speed = flight.maxSpeed {
            stats.append(("VITESSE MAX", "\(Int(speed * 3.6)) km/h", "speedometer"))
        }
        if let startAlt = flight.startAltitude, let endAlt = flight.endAltitude {
            let gain = startAlt - endAlt
            let gainStr = gain >= 0 ? "+\(Int(gain)) m" : "\(Int(gain)) m"
            stats.append(("DÉNIVELÉ", gainStr, "arrow.up.arrow.down"))
        }

        // Dessiner les cartes de stats
        for (index, stat) in stats.prefix(4).enumerated() {
            let col = index % 2
            let row = index / 2

            let cardX = padding + CGFloat(col) * (cardWidth + padding)
            let cardY = statsY + CGFloat(row) * (cardHeight + 15)

            drawStatCardLocal(
                label: stat.label,
                value: stat.value,
                in: CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
                context: context
            )
        }

        // Date et voile en bas
        let bottomY = rect.height * 0.88

        // Date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.locale = Locale(identifier: "fr_FR")
        let dateStr = dateFormatter.string(from: flight.date)

        let dateFont = UIFont.systemFont(ofSize: 28, weight: .regular)
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: dateFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.6)
        ]
        let dateSize = dateStr.size(withAttributes: dateAttrs)
        let dateRect = CGRect(
            x: (rect.width - dateSize.width) / 2,
            y: bottomY,
            width: dateSize.width,
            height: dateSize.height
        )
        dateStr.draw(in: dateRect, withAttributes: dateAttrs)

        // Voile (si disponible)
        if let wing = flight.wing {
            let wingFont = UIFont.systemFont(ofSize: 24, weight: .medium)
            let wingAttrs: [NSAttributedString.Key: Any] = [
                .font: wingFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.5)
            ]
            let wingText = "\(wing.brand) \(wing.model)"
            let wingSize = wingText.size(withAttributes: wingAttrs)
            let wingRect = CGRect(
                x: (rect.width - wingSize.width) / 2,
                y: dateRect.maxY + 8,
                width: wingSize.width,
                height: wingSize.height
            )
            wingText.draw(in: wingRect, withAttributes: wingAttrs)
        }
    }

    private func drawStatCardLocal(label: String, value: String, in rect: CGRect, context: UIGraphicsImageRendererContext) {
        let cgContext = context.cgContext

        // Fond semi-transparent
        cgContext.setFillColor(UIColor.white.withAlphaComponent(0.1).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
        cgContext.addPath(path.cgPath)
        cgContext.fillPath()

        // Label
        let labelFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.6)
        ]
        let labelSize = label.size(withAttributes: labelAttrs)
        let labelRect = CGRect(
            x: rect.midX - labelSize.width / 2,
            y: rect.minY + 15,
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(in: labelRect, withAttributes: labelAttrs)

        // Value
        let valueFont = UIFont.systemFont(ofSize: 32, weight: .bold)
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: UIColor.white
        ]
        let valueSize = value.size(withAttributes: valueAttrs)
        let valueRect = CGRect(
            x: rect.midX - valueSize.width / 2,
            y: labelRect.maxY + 8,
            width: valueSize.width,
            height: valueSize.height
        )
        value.draw(in: valueRect, withAttributes: valueAttrs)
    }

    // MARK: - Local Flight Share Text

    /// Génère le texte de partage pour un vol local
    func generateLocalFlightShareText(flight: Flight) -> String {
        var text = "Vol de \(flight.durationFormatted)"

        if let spotName = flight.spotName, !spotName.isEmpty {
            text += " @ \(spotName)"
        }

        text += "\n\n"

        if let altitude = flight.maxAltitude {
            text += "Alt. max: \(Int(altitude))m\n"
        }

        if let distance = flight.totalDistance {
            if distance >= 1000 {
                text += "Distance: \(String(format: "%.1f", distance / 1000))km\n"
            } else {
                text += "Distance: \(Int(distance))m\n"
            }
        }

        if let wing = flight.wing {
            text += "Voile: \(wing.brand) \(wing.model)\n"
        }

        text += "\n#Parapente #Paragliding #SoarX"

        return text
    }
}
