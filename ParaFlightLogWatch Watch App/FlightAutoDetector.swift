//
//  FlightAutoDetector.swift
//  ParaFlightLogWatch Watch App
//
//  Détection automatique décollage / atterrissage (opt-in).
//  Machine à états pure et testable : aucune dépendance UI/capteur,
//  le câblage (timers, GPS, vario, alertes) vit dans ContentView.
//  Target: Watch only
//

import Foundation

// MARK: - États

/// État de la détection automatique
enum FlightAutoDetectorState: Equatable {
    /// Inactif (autoDetect désactivé, ou pas sur l'écran de départ)
    case idle
    /// Armé : surveille la vitesse sol pour détecter le décollage
    case armed
    /// Vol en cours : surveille la vitesse sol pour détecter l'atterrissage
    case flying
    /// Candidat atterrissage : vitesse faible, accumulation du temps de confirmation
    case landingCandidate
    /// Vol en pause au sol (mode soaring) : attend un redécollage ou le timeout de pause
    case pausedOnGround
}

/// Comportement à la confirmation d'un atterrissage
enum LandingBehavior: Equatable {
    /// Comportement classique (Thermique) : émet `onLandingDetected` → arrêt du vol
    case stop
    /// Mode soaring : le vol passe en pause au sol et reprend au redécollage.
    /// `maxPause` : durée maximale de pause avant arrêt automatique (`onPauseTimeout`).
    case pauseAndResume(maxPause: TimeInterval)
}

// MARK: - Machine à états

/// Machine à états de détection décollage/atterrissage, alimentée à ~1 Hz
/// par `update(speed:vz:gpsAltitude:timestamp:)`.
/// - Décollage : vitesse sol > seuil pendant la durée de confirmation → `onTakeoffDetected`
/// - Atterrissage : vitesse sol < seuil ET altitude stable (Vz vario si dispo,
///   sinon altitude GPS ± tolérance) pendant la durée de confirmation →
///   selon `landingBehavior` : `onLandingDetected` (.stop) ou pause au sol
///   (.pauseAndResume : `onPauseStarted` → `onResumed` au redécollage,
///   ou `onPauseTimeout` si la pause dépasse la durée maximale)
final class FlightAutoDetector {

    // MARK: - Réglages (exposés pour les tests)

    /// Vitesse sol minimale de décollage (m/s) — 4 m/s ≈ 14 km/h
    var takeoffSpeedThreshold: Double = 4.0
    /// Durée de vitesse soutenue pour confirmer le décollage (s)
    var takeoffConfirmation: TimeInterval = 5.0
    /// Vitesse sol maximale d'atterrissage (m/s)
    var landingSpeedThreshold: Double = 1.5
    /// Durée de vitesse faible pour confirmer l'atterrissage (s)
    var landingConfirmation: TimeInterval = 90.0
    /// |Vz| maximale considérée comme « altitude stable » (m/s) quand la Vz vario est dispo
    var landingVzThreshold: Double = 0.5
    /// Tolérance de stabilité d'altitude GPS (m) quand la Vz n'est pas dispo
    var landingAltitudeTolerance: Double = 3.0
    /// Comportement à la confirmation d'atterrissage (.stop par défaut = comportement historique)
    var landingBehavior: LandingBehavior = .stop

    // MARK: - Callbacks

    /// Décollage confirmé (vitesse soutenue pendant la durée requise)
    var onTakeoffDetected: (() -> Void)?
    /// Atterrissage confirmé en mode .stop (l'UI affiche alors son compte à rebours)
    var onLandingDetected: (() -> Void)?
    /// Atterrissage confirmé en mode .pauseAndResume : le vol passe en pause au sol
    var onPauseStarted: (() -> Void)?
    /// Redécollage détecté pendant la pause : le MÊME vol reprend
    var onResumed: (() -> Void)?
    /// La pause a dépassé `maxPause` : l'UI doit arrêter le vol
    var onPauseTimeout: (() -> Void)?

    /// État courant (lecture seule)
    private(set) var state: FlightAutoDetectorState = .idle

    // MARK: - Interne

    /// Début de la fenêtre de vitesse soutenue (décollage)
    private var takeoffCandidateSince: TimeInterval?
    /// Début de la fenêtre de vitesse faible (atterrissage)
    private var landingCandidateSince: TimeInterval?
    /// Altitude GPS de référence au début du candidat atterrissage
    private var landingReferenceAltitude: Double?
    /// Vrai quand `onLandingDetected` a été émis (compte à rebours UI en cours)
    private var landingNotified = false
    /// Début de la pause au sol (mode .pauseAndResume)
    private var pauseStartedAt: TimeInterval?
    /// Vrai quand `onPauseTimeout` a été émis (l'UI arrête le vol)
    private var pauseTimeoutNotified = false

    // MARK: - Transitions pilotées par l'UI

    /// Arme la détection de décollage (écran de départ + voile sélectionnée + autoDetect ON)
    func arm() {
        guard state == .idle else { return }
        state = .armed
        resetCandidates()
    }

    /// Désarme complètement (autoDetect OFF, sortie de l'écran de départ…)
    func disarm() {
        state = .idle
        resetCandidates()
    }

    /// Un vol démarre (manuellement ou automatiquement) : surveille l'atterrissage
    func flightStarted() {
        state = .flying
        resetCandidates()
    }

    /// Le vol est terminé ou annulé : retour à l'inactif
    func flightStopped() {
        state = .idle
        resetCandidates()
    }

    /// L'utilisateur a choisi « Continuer le vol » : on repart de zéro
    func landingDismissed() {
        guard state == .landingCandidate || state == .flying else { return }
        state = .flying
        resetCandidates()
    }

    private func resetCandidates() {
        takeoffCandidateSince = nil
        landingCandidateSince = nil
        landingReferenceAltitude = nil
        landingNotified = false
        pauseStartedAt = nil
        pauseTimeoutNotified = false
    }

    // MARK: - Mise à jour (logique pure)

    /// Intègre une mesure.
    /// - Parameters:
    ///   - speed: vitesse sol GPS (m/s), nil si indisponible
    ///   - vz: Vz vario filtrée (m/s) si le baro est fiable, sinon nil
    ///   - gpsAltitude: altitude GPS (m), secours pour la stabilité d'altitude
    ///   - timestamp: horloge croissante (epoch ou monotone, peu importe — seuls les deltas comptent)
    func update(speed: Double?, vz: Double? = nil, gpsAltitude: Double? = nil, timestamp: TimeInterval) {
        switch state {
        case .idle:
            return   // Jamais d'interférence quand la détection est désactivée
        case .armed:
            updateTakeoff(speed: speed, timestamp: timestamp)
        case .flying, .landingCandidate:
            updateLanding(speed: speed, vz: vz, gpsAltitude: gpsAltitude, timestamp: timestamp)
        case .pausedOnGround:
            updatePausedOnGround(speed: speed, timestamp: timestamp)
        }
    }

    // MARK: - Décollage

    private func updateTakeoff(speed: Double?, timestamp: TimeInterval) {
        // Vitesse retombée sous le seuil (ou GPS muet) : on repart de zéro
        guard let speed, speed > takeoffSpeedThreshold else {
            takeoffCandidateSince = nil
            return
        }

        guard let since = takeoffCandidateSince else {
            takeoffCandidateSince = timestamp
            return
        }

        if timestamp - since >= takeoffConfirmation {
            takeoffCandidateSince = nil
            state = .flying   // flightStarted() rappelé par l'UI : idempotent
            onTakeoffDetected?()
        }
    }

    // MARK: - Atterrissage

    private func updateLanding(speed: Double?, vz: Double?, gpsAltitude: Double?, timestamp: TimeInterval) {
        // Compte à rebours UI en cours : ne pas ré-émettre
        guard !landingNotified else { return }

        // Condition 1 : sol quasi immobile
        guard let speed, speed < landingSpeedThreshold else {
            cancelLandingCandidate()
            return
        }

        // Condition 2 : altitude stable — Vz vario si dispo, sinon altitude GPS ± tolérance
        if let vz {
            guard abs(vz) < landingVzThreshold else {
                cancelLandingCandidate()
                return
            }
        } else if let gpsAltitude {
            if let reference = landingReferenceAltitude {
                guard abs(gpsAltitude - reference) <= landingAltitudeTolerance else {
                    cancelLandingCandidate()
                    return
                }
            } else {
                landingReferenceAltitude = gpsAltitude
            }
        }
        // Ni Vz ni altitude dispo : la vitesse seule fait foi (mode dégradé)

        guard let since = landingCandidateSince else {
            landingCandidateSince = timestamp
            state = .landingCandidate
            return
        }

        if timestamp - since >= landingConfirmation {
            switch landingBehavior {
            case .stop:
                // Comportement classique (Thermique) : l'UI affiche son compte à rebours
                landingNotified = true
                onLandingDetected?()
            case .pauseAndResume:
                // Mode soaring : le vol passe en pause au sol, on attend le redécollage
                state = .pausedOnGround
                resetCandidates()
                pauseStartedAt = timestamp
                onPauseStarted?()
            }
        }
    }

    // MARK: - Pause au sol (mode soaring)

    /// En pause : surveille le redécollage (même logique/seuils que le décollage
    /// initial) et le dépassement de la durée maximale de pause.
    private func updatePausedOnGround(speed: Double?, timestamp: TimeInterval) {
        // Garde-fou : pause trop longue → arrêt automatique du vol (émis une seule fois)
        if case .pauseAndResume(let maxPause) = landingBehavior,
           let pauseStart = pauseStartedAt,
           timestamp - pauseStart >= maxPause {
            if !pauseTimeoutNotified {
                pauseTimeoutNotified = true
                onPauseTimeout?()
            }
            return
        }
        guard !pauseTimeoutNotified else { return }

        // Redécollage : vitesse sol soutenue au-dessus du seuil de décollage
        guard let speed, speed > takeoffSpeedThreshold else {
            takeoffCandidateSince = nil
            return
        }

        guard let since = takeoffCandidateSince else {
            takeoffCandidateSince = timestamp
            return
        }

        if timestamp - since >= takeoffConfirmation {
            // Reprise du MÊME vol : retour en surveillance d'atterrissage
            state = .flying
            resetCandidates()
            onResumed?()
        }
    }

    private func cancelLandingCandidate() {
        landingCandidateSince = nil
        landingReferenceAltitude = nil
        if state == .landingCandidate {
            state = .flying
        }
    }
}
