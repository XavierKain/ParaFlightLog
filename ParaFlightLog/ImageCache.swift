//
//  ImageCache.swift
//  ParaFlightLog
//
//  Cache d'images pour éviter le décodage répété des thumbnails
//  Utilise NSCache pour une gestion mémoire automatique
//  Target: iOS only
//

import UIKit
import SwiftUI

// MARK: - Image Cache Manager

/// Cache centralisé pour les images décodées (voiles, etc.)
/// Évite de décoder les Data en UIImage à chaque rendu de cellule
final class ImageCacheManager {
    static let shared = ImageCacheManager()

    // NSCache gère automatiquement la mémoire
    private let cache = NSCache<NSString, UIImage>()

    // Limite configurable
    private let maxCacheCount = 50

    private init() {
        cache.countLimit = maxCacheCount
        cache.name = "com.paraflightlog.imageCache"

        // Observer les warnings mémoire
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearCache),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Récupère une image du cache ou la décode et la met en cache
    /// - Parameters:
    ///   - data: Les données de l'image
    ///   - key: Clé unique (généralement l'UUID de l'entité)
    ///   - size: Taille cible pour le redimensionnement (optionnel)
    /// - Returns: UIImage décodée ou nil
    func image(for data: Data, key: String, targetSize: CGSize? = nil) -> UIImage? {
        let cacheKey = makeCacheKey(key: key, size: targetSize)

        // Vérifier le cache
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        // Décoder l'image
        guard let image = UIImage(data: data) else {
            return nil
        }

        // Redimensionner si nécessaire
        let finalImage: UIImage
        if let targetSize = targetSize {
            finalImage = image.resized(to: targetSize) ?? image
        } else {
            finalImage = image
        }

        // Mettre en cache
        cache.setObject(finalImage, forKey: cacheKey)

        return finalImage
    }

    /// Invalide l'entrée de cache pour une clé donnée
    func invalidate(key: String) {
        // Invalider toutes les tailles pour cette clé
        let baseKey = key as NSString
        cache.removeObject(forKey: baseKey)

        // Invalider aussi les versions avec taille
        for size in [60, 80, 100, 120] {
            let sizedKey = "\(key)_\(size)x\(size)" as NSString
            cache.removeObject(forKey: sizedKey)
        }
    }

    /// Vide entièrement le cache
    @objc func clearCache() {
        cache.removeAllObjects()
        logDebug("Image cache cleared", category: .imageProcessing)
    }

    // MARK: - Private

    private func makeCacheKey(key: String, size: CGSize?) -> NSString {
        if let size = size {
            return "\(key)_\(Int(size.width))x\(Int(size.height))" as NSString
        }
        return key as NSString
    }
}

// MARK: - UIImage Extension

extension UIImage {
    /// Redimensionne l'image à la taille cible
    func resized(to targetSize: CGSize) -> UIImage? {
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let ratio = max(widthRatio, heightRatio)

        let newSize = CGSize(
            width: size.width * ratio,
            height: size.height * ratio
        )

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            let origin = CGPoint(
                x: (targetSize.width - newSize.width) / 2,
                y: (targetSize.height - newSize.height) / 2
            )
            draw(in: CGRect(origin: origin, size: newSize))
        }
    }
}

// MARK: - CachedAsyncImage View

/// Vue SwiftUI qui affiche une image avec cache intégré
struct CachedImage: View {
    let data: Data?
    let key: String
    let size: CGSize
    let placeholder: AnyView

    @State private var image: UIImage?

    init(
        data: Data?,
        key: String,
        size: CGSize,
        @ViewBuilder placeholder: () -> some View = { Color.gray.opacity(0.3) }
    ) {
        self.data = data
        self.key = key
        self.size = size
        self.placeholder = AnyView(placeholder())
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            loadImage()
        }
        .onChange(of: data) { _, newData in
            if newData != nil {
                loadImage()
            } else {
                image = nil
            }
        }
    }

    private func loadImage() {
        guard let data = data else {
            image = nil
            return
        }

        // Charger depuis le cache ou décoder en background
        if let cached = ImageCacheManager.shared.image(for: data, key: key, targetSize: size) {
            image = cached
        } else {
            // Décoder en background pour les grosses images
            Task.detached(priority: .userInitiated) {
                let decoded = ImageCacheManager.shared.image(for: data, key: key, targetSize: size)
                await MainActor.run {
                    image = decoded
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        CachedImage(
            data: nil,
            key: "preview",
            size: CGSize(width: 60, height: 60)
        ) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.3))
                .overlay {
                    Image(systemName: "wind")
                        .foregroundStyle(.blue)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
