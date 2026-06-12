//
//  ParaFlightLogWidget.swift
//  ParaFlightLogWidgetExtension
//
//  Widget/Complication pour le cadran Apple Watch
//  Target: Widget Extension
//

import SwiftUI
import WidgetKit

// MARK: - Localization Helper

/// Helper pour les chaînes localisées du widget
/// Lit la langue depuis les UserDefaults de l'app Watch (synchronisée depuis iPhone)
private enum WidgetStrings {
    /// Clé utilisée par WatchLocalizationManager pour stocker la langue
    private static let languageKey = "watch_app_language"
    
    /// Vérifie si la langue sélectionnée dans l'app est le français
    private static var isFrench: Bool {
        // Lire la langue depuis UserDefaults (partagé avec l'app Watch)
        if let languageCode = UserDefaults.standard.string(forKey: languageKey) {
            return languageCode == "fr"
        }
        // Fallback: utiliser la langue du système
        return Locale.current.language.languageCode?.identifier == "fr"
    }
    
    static var startFlight: String {
        isFrench ? "Démarrer un vol" : "Start a flight"
    }
    
    static var description: String {
        isFrench ? "Affiche le statut de vol et accès rapide" : "Shows flight status and quick access"
    }
    
    static var flight: String {
        isFrench ? "Vol" : "Flight"
    }
}

// MARK: - Timeline Entry

struct FlightEntry: TimelineEntry {
    let date: Date
    let isFlying: Bool
    let flightStartDate: Date?
    let wingName: String?

    /// Entrée "au repos"
    static func idle(date: Date = Date()) -> FlightEntry {
        FlightEntry(date: date, isFlying: false, flightStartDate: nil, wingName: nil)
    }
}

// MARK: - Timeline Provider

struct FlightWidgetProvider: TimelineProvider {
    /// Lit l'état du vol en cours depuis l'App Group (écrit par l'app Watch)
    private func currentEntry(date: Date = Date()) -> FlightEntry {
        let state = WidgetFlightState.read()
        if state.isFlying, let startDate = state.startDate {
            return FlightEntry(date: date, isFlying: true, flightStartDate: startDate, wingName: state.wingName)
        }
        return .idle(date: date)
    }

    func placeholder(in context: Context) -> FlightEntry {
        .idle()
    }

    func getSnapshot(in context: Context, completion: @escaping (FlightEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlightEntry>) -> Void) {
        let entry = currentEntry()
        let now = Date()

        // En vol : le chrono est rendu par Text(style: .timer) qui tourne tout seul,
        // on rafraîchit la timeline toutes les 30 min par sécurité.
        // Au repos : rafraîchissement passif (l'app Watch force un reload au start/stop).
        let refreshMinutes = entry.isFlying ? 30 : 60
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: now) ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget Views

struct FlightWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: FlightEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            RectangularWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            InlineWidgetView(entry: entry)
        case .accessoryCorner:
            CornerWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        default:
            CircularWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
    }
}

// Vue circulaire (pour les complications circulaires)
struct CircularWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        if entry.isFlying, let startDate = entry.flightStartDate {
            // Pendant un vol : afficher le chrono (mis à jour en continu par le système)
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "timer")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                    Text(startDate, style: .timer)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            // Au repos : afficher l'icône de l'app (version circulaire)
            ZStack {
                AccessoryWidgetBackground()
                Image("WidgetIconCircular")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
            }
        }
    }
}

// Vue rectangulaire (pour les complications rectangulaires)
struct RectangularWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        HStack(spacing: 8) {
            // Icône avec SF Symbol
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.ultraThinMaterial)
                    .frame(width: 26, height: 26)
                Image(systemName: "wind")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                if entry.isFlying, let startDate = entry.flightStartDate {
                    Text(startDate, style: .timer)
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()

                    if let wingName = entry.wingName {
                        Text(wingName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("SoarX")
                        .font(.headline)

                    Text(WidgetStrings.startFlight)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
    }
}

// Vue coin (pour la complication de coin)
struct CornerWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        Image(systemName: "wind")
            .font(.system(size: 20, weight: .semibold))
            .widgetLabel {
                Text(WidgetStrings.flight)
            }
    }
}

// Vue inline (pour les complications simples)
struct InlineWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        if entry.isFlying, let startDate = entry.flightStartDate {
            Label {
                Text(startDate, style: .timer)
            } icon: {
                Image(systemName: "play.fill")
            }
            .fontWeight(.semibold)
        } else {
            Label("SoarX", systemImage: "wind")
        }
    }
}

// MARK: - Widget Configuration

struct ParaFlightLogWidget: Widget {
    let kind: String = "ParaFlightLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FlightWidgetProvider()) { entry in
            FlightWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("SoarX")
        .description(WidgetStrings.description)
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Preview

#Preview(as: .accessoryCircular) {
    ParaFlightLogWidget()
} timeline: {
    FlightEntry.idle()
    FlightEntry(date: .now, isFlying: true, flightStartDate: .now.addingTimeInterval(-83 * 60), wingName: "Flare Props")
}

#Preview(as: .accessoryRectangular) {
    ParaFlightLogWidget()
} timeline: {
    FlightEntry.idle()
    FlightEntry(date: .now, isFlying: true, flightStartDate: .now.addingTimeInterval(-83 * 60), wingName: "Flare Props")
}
