//
//  UIImage+Resize.swift
//  ParaFlightLog
//
//  Extension UIImage pour le redimensionnement avec préservation de la transparence
//  Factorise le code de redimensionnement utilisé pour la synchronisation Watch
//  Target: iOS only
//

import UIKit

extension UIImage {

    /// Redimensionne l'image à une taille maximale en préservant les proportions et la transparence
    /// - Parameters:
    ///   - maxSize: Taille maximale en points (largeur ou hauteur)
    ///   - preserveTransparency: Si true, encode en PNG pour préserver la transparence (défaut: true)
    /// - Returns: Les données de l'image redimensionnée (PNG si transparency, sinon JPEG)
    func resized(maxSize: CGFloat, preserveTransparency: Bool = true) -> Data? {
        // Calculer le facteur d'échelle
        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)

        // Si l'image est déjà plus petite, retourner les données originales
        if scale >= 1.0 {
            return preserveTransparency ? pngData() : jpegData(compressionQuality: 0.8)
        }

        let targetSize = CGSize(
            width: max(1, round(size.width * scale)),
            height: max(1, round(size.height * scale))
        )

        // Configurer le renderer avec ou sans transparence
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = !preserveTransparency

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return preserveTransparency ? resizedImage.pngData() : resizedImage.jpegData(compressionQuality: 0.8)
    }

    /// Crée une miniature de l'image
    /// - Parameters:
    ///   - size: Taille de la miniature (défaut: 72x72)
    ///   - preserveTransparency: Préserve la transparence (défaut: true)
    /// - Returns: Les données de la miniature
    func thumbnail(size: CGFloat = 72, preserveTransparency: Bool = true) -> Data? {
        return resized(maxSize: size, preserveTransparency: preserveTransparency)
    }

    /// Redimensionne l'image pour la Watch (120x120 max avec transparence)
    func resizedForWatch() -> Data? {
        return resized(maxSize: 120, preserveTransparency: true)
    }

    /// Crée une miniature pour la Watch (72x72 max avec transparence)
    func thumbnailForWatch() -> Data? {
        return resized(maxSize: 72, preserveTransparency: true)
    }
}
