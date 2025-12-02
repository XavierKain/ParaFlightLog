//
//  ParaFlightLogWidget.swift
//  ParaFlightLogWidgetExtension
//
//  Widget/Complication pour le cadran Apple Watch
//  Target: Widget Extension
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
        let entry = FlightEntry(
            date: Date(),
            isFlying: false,
            elapsedTime: "00:00",
            wingName: nil
        )

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
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
        HStack(spacing: 6) {
            Image(systemName: entry.isFlying ? "play.fill" : "paragliding")
                .font(.title3)
                .foregroundStyle(entry.isFlying ? .green : .primary)

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

                    Text("Lancer un vol")
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
        Image(systemName: "paragliding")
            .font(.title2)
            .widgetLabel {
                Text("Vol")
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
            Label("ParaFlightLog", systemImage: "paragliding")
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
        .description("Lancez l'app et suivez vos vols")
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
