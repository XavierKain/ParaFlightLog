//
//  ParaFlightLogWidget.swift
//  ParaFlightLogWatch Watch App
//
//  Widget/Complication pour le cadran Apple Watch
//  Target: Watch only
//

import SwiftUI
import WidgetKit

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
        // Pour l'instant, pas de vol en cours
        // TODO: Récupérer l'état du vol depuis UserDefaults ou App Group
        let entry = FlightEntry(
            date: Date(),
            isFlying: false,
            elapsedTime: "00:00",
            wingName: nil
        )

        // Mettre à jour toutes les 60 secondes
        let nextUpdate = Calendar.current.date(byAdding: .second, value: 60, to: Date())!
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
            // Pendant un vol : afficher le chrono avec jauge
            Gauge(value: 0.5) {
                Image(systemName: "paragliding")
                    .font(.system(size: 20))
            } currentValueLabel: {
                Text(entry.elapsedTime)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            // Au repos : afficher l'icône de l'app (parapente)
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "paragliding")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }
}

// Vue rectangulaire (pour les complications rectangulaires)
struct RectangularWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.isFlying ? "play.fill" : "wind")
                .foregroundStyle(entry.isFlying ? .green : .blue)

            VStack(alignment: .leading, spacing: 1) {
                if entry.isFlying {
                    Text(entry.elapsedTime)
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()

                    if let wingName = entry.wingName {
                        Text(wingName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("ParaFlightLog")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Text("Lancer un vol")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// Vue inline (pour les complications simples)
struct InlineWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        if entry.isFlying {
            Text("\(Image(systemName: "play.fill")) \(entry.elapsedTime)")
                .fontWeight(.semibold)
        } else {
            Text("\(Image(systemName: "wind")) ParaFlightLog")
        }
    }
}

// MARK: - Widget Configuration
// NOTE: Pour activer ce widget, il faut créer un Widget Extension séparé dans Xcode
// File > New > Target > Watch Widget Extension

struct ParaFlightLogWidget: Widget {
    let kind: String = "ParaFlightLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FlightWidgetProvider()) { entry in
            FlightWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("ParaFlightLog")
        .description("Suivez vos vols de parapente")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
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

#Preview(as: .accessoryInline) {
    ParaFlightLogWidget()
} timeline: {
    FlightEntry(date: .now, isFlying: false, elapsedTime: "00:00", wingName: nil)
    FlightEntry(date: .now, isFlying: true, elapsedTime: "01:23", wingName: "Flare Props")
}
