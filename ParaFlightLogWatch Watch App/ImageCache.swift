//
//  ImageCache.swift
//  ParaFlightLogWatch Watch App
//
//  Cache d'images pour éviter le décodage répété des Data -> UIImage
//  Utilise NSCache pour une gestion automatique de la mémoire
//  Target: Watch only
//

import SwiftUI
import WatchKit

/// Wrapper pour stocker UIImage dans NSCache (qui nécessite des objets NSObject)
private final class ImageWrapper: NSObject {
    let image: UIImage
    init(_ image: UIImage) {
        self.image = image
    }
}

/// Wrapper pour utiliser UUID comme clé dans NSCache
private final class UUIDKey: NSObject {
    let uuid: UUID
    init(_ uuid: UUID) {
        self.uuid = uuid
    }

    override var hash: Int {
        return uuid.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UUIDKey else { return false }
        return uuid == other.uuid
    }
}

/// Cache singleton pour les images des voiles
/// Utilise NSCache pour une gestion automatique de la mémoire avec limite
final class WatchImageCache {
    static let shared = WatchImageCache()

    // NSCache gère automatiquement l'éviction des éléments en cas de pression mémoire
    private let cache = NSCache<UUIDKey, ImageWrapper>()
    private let queue = DispatchQueue(label: "com.paraflightlog.imagecache", qos: .userInitiated)

    // Configuration du cache
    private let maxCacheCount = 20  // Maximum 20 images en cache (suffisant pour les voiles)
    private let maxCacheCostMB = 10 // Maximum ~10 MB de mémoire

    private init() {
        // Configurer les limites du cache
        cache.countLimit = maxCacheCount
        cache.totalCostLimit = maxCacheCostMB * 1024 * 1024  // Convertir en bytes
    }

    /// Calcule le coût mémoire réel d'une UIImage (en bytes)
    /// Le coût est basé sur la taille en pixels × 4 bytes par pixel (RGBA)
    private func memoryCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            // Fallback: estimation basée sur la taille logique
            return Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
        }
        return cgImage.width * cgImage.height * 4  // 4 bytes par pixel (RGBA)
    }
    
    /// Récupère une image du cache ou la décode si nécessaire
    func image(for wingId: UUID, data: Data?) -> UIImage? {
        let key = UUIDKey(wingId)

        // Vérifier le cache d'abord (synchrone pour la lecture)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        // Pas de données, pas d'image
        guard let data = data else { return nil }

        // Décoder l'image
        guard let image = UIImage(data: data) else { return nil }

        // Mettre en cache avec le coût = taille mémoire réelle de l'UIImage
        let cost = memoryCost(for: image)
        cache.setObject(ImageWrapper(image), forKey: key, cost: cost)

        return image
    }

    /// Précharge les images en arrière-plan
    func preloadImages(for wings: [WingDTO]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            for wing in wings {
                guard let data = wing.photoData else { continue }
                let key = UUIDKey(wing.id)
                if self.cache.object(forKey: key) == nil {
                    if let image = UIImage(data: data) {
                        let cost = self.memoryCost(for: image)
                        DispatchQueue.main.async {
                            self.cache.setObject(ImageWrapper(image), forKey: key, cost: cost)
                        }
                    }
                }
            }
        }
    }

    /// Vide le cache
    func clearCache() {
        cache.removeAllObjects()
    }

    /// Supprime une image du cache
    func removeImage(for wingId: UUID) {
        cache.removeObject(forKey: UUIDKey(wingId))
    }

    /// Précharge une image de façon synchrone (pour éviter le lag au premier vol)
    func preloadImageSync(for wing: WingDTO) {
        guard let data = wing.photoData else { return }
        let key = UUIDKey(wing.id)
        guard cache.object(forKey: key) == nil else { return }

        if let image = UIImage(data: data) {
            let cost = memoryCost(for: image)
            cache.setObject(ImageWrapper(image), forKey: key, cost: cost)
        }
    }

    /// Vérifie si une image est en cache (pour accès direct depuis les vues)
    func cachedImage(for wingId: UUID) -> UIImage? {
        return cache.object(forKey: UUIDKey(wingId))?.image
    }
}

/// Vue SwiftUI pour afficher une image de voile avec cache
/// Le fond s'adapte au contexte (sélectionné ou non) pour masquer le fond blanc des images
struct CachedWingImage: View {
    let wing: WingDTO
    let size: CGFloat
    var isSelected: Bool = false
    var showBackground: Bool = true

    @State private var cachedImage: UIImage?

    // Couleur de fond qui correspond au fond du bouton
    private var backgroundColor: Color {
        if !showBackground {
            return .clear
        }
        return isSelected ? Color.green.opacity(0.12) : Color.gray.opacity(0.15)
    }

    var body: some View {
        Group {
            if let image = cachedImage {
                // Afficher l'image originale (le fond blanc est supprimé côté iPhone)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Placeholder pendant le chargement ou si pas d'image
                Image(systemName: "wind")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.blue)
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: wing.photoData) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        // Vérifier le cache immédiatement (synchrone)
        if let cached = WatchImageCache.shared.cachedImage(for: wing.id) {
            cachedImage = cached
            return
        }

        // Si pas en cache, décoder en arrière-plan pour ne pas bloquer l'UI
        guard let data = wing.photoData else { return }
        let wingId = wing.id

        Task.detached(priority: .userInitiated) {
            // Décoder l'image en arrière-plan
            guard let image = UIImage(data: data) else { return }

            await MainActor.run {
                // Mettre en cache et afficher
                _ = WatchImageCache.shared.image(for: wingId, data: data)
                cachedImage = image
            }
        }
    }
}
