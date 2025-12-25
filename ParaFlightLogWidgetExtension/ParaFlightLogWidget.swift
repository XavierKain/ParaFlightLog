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
    let elapsedTime: String
    let wingName: String?
}

// MARK: - Timeline Provider

struct FlightWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FlightEntry {
        FlightEntry(
            date: Date(),
            isFlying: false,
            elapsedTime: "00:00",
            wingName: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (FlightEntry) -> Void) {
        let entry = FlightEntry(
            date: Date(),
            isFlying: false,
            elapsedTime: "00:00",
            wingName: nil
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlightEntry>) -> Void) {
        let entry = FlightEntry(
            date: Date(),
            isFlying: false,
            elapsedTime: "00:00",
            wingName: nil
        )

        let now = Date()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(15 * 60)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
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
        if entry.isFlying {
            // Pendant un vol : afficher le chrono
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "timer")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                    Text(entry.elapsedTime)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
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
                if entry.isFlying {
                    Text(entry.elapsedTime)
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()

                    if let wingName = entry.wingName {
                        Text(wingName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("ParaFlightLog")
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
        if entry.isFlying {
            Label(entry.elapsedTime, systemImage: "play.fill")
                .fontWeight(.semibold)
        } else {
            Label("ParaFlightLog", systemImage: "wind")
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
        .configurationDisplayName("ParaFlightLog")
        .description(WidgetStrings.description)
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}

// MARK: - Preview

#Preview(as: .accessoryCircular) {
    ParaFlightLogWidget()
} timeline: {
    FlightEntry(date: .now, isFlying: false, elapsedTime: "00:00", wingName: nil)
    FlightEntry(date: .now, isFlying: true, elapsedTime: "01:23", wingName: "Flare Props")
}

#Preview(as: .accessoryRectangular) {
    ParaFlightLogWidget()
} timeline: {
    FlightEntry(date: .now, isFlying: false, elapsedTime: "00:00", wingName: nil)
    FlightEntry(date: .now, isFlying: true, elapsedTime: "01:23", wingName: "Flare Props")
}
