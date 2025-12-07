//
//  ImageCache.swift
//  ParaFlightLogWatch Watch App
//
//  Cache d'images pour éviter le décodage répété des Data -> UIImage
//  Target: Watch only
//

import SwiftUI
import WatchKit

/// Cache singleton pour les images des voiles
final class WatchImageCache {
    static let shared = WatchImageCache()

    fileprivate var cache: [UUID: UIImage] = [:]
    private let queue = DispatchQueue(label: "com.paraflightlog.imagecache", qos: .userInitiated)

    private init() {}
    
    /// Récupère une image du cache ou la décode si nécessaire
    func image(for wingId: UUID, data: Data?) -> UIImage? {
        // Vérifier le cache d'abord (synchrone pour la lecture)
        if let cached = cache[wingId] {
            return cached
        }
        
        // Pas de données, pas d'image
        guard let data = data else { return nil }
        
        // Décoder l'image
        guard let image = UIImage(data: data) else { return nil }
        
        // Mettre en cache
        cache[wingId] = image
        
        return image
    }
    
    /// Précharge les images en arrière-plan
    func preloadImages(for wings: [WingDTO]) {
        queue.async { [weak self] in
            for wing in wings {
                guard let data = wing.photoData else { continue }
                if self?.cache[wing.id] == nil {
                    if let image = UIImage(data: data) {
                        DispatchQueue.main.async {
                            self?.cache[wing.id] = image
                        }
                    }
                }
            }
        }
    }
    
    /// Vide le cache
    func clearCache() {
        cache.removeAll()
    }
    
    /// Supprime une image du cache
    func removeImage(for wingId: UUID) {
        cache.removeValue(forKey: wingId)
    }
}

/// Vue SwiftUI pour afficher une image de voile avec cache
struct CachedWingImage: View {
    let wing: WingDTO
    let size: CGFloat

    // OPTIMISATION WATCH: Désactiver les images pour améliorer les performances
    // Les images ralentissent considérablement l'app Watch
    private let disableImages = true

    @State private var cachedImage: UIImage?

    var body: some View {
        Group {
            if !disableImages, let image = cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Placeholder pendant le chargement ou si pas d'image
                Image(systemName: "wind")
                    .font(size > 30 ? .headline : .title3)
                    .foregroundStyle(.blue)
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            if !disableImages {
                loadImage()
            }
        }
        .onChange(of: wing.photoData) { _, _ in
            if !disableImages {
                loadImage()
            }
        }
    }

    private func loadImage() {
        // Vérifier le cache immédiatement (synchrone)
        if let cached = WatchImageCache.shared.cache[wing.id] {
            cachedImage = cached
            return
        }

        // Si pas en cache, décoder en arrière-plan pour ne pas bloquer l'UI
        guard let data = wing.photoData else { return }

        Task.detached(priority: .userInitiated) {
            if let image = UIImage(data: data) {
                await MainActor.run {
                    WatchImageCache.shared.cache[wing.id] = image
                    cachedImage = image
                }
            }
        }
    }
}
