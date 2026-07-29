//
//  ParaFlightLogWidget.swift
//  ParaFlightLogWidgetExtension
//
//  Widget/Complication pour le cadran Apple Watch
//  Target: Widget Extension
//

import SwiftUI
import WidgetKit

// NOTE: this extension used to carry a hand-rolled FR/EN switch (WidgetStrings,
// reading a "watch_app_language" default written by the v1 localization
// manager). Nothing writes that default any more, and the app now ships a real
// string catalog localized to en/fr/de — so the strings below are plain
// LocalizedStringKey / LocalizedStringResource literals and get translated by
// the standard mechanism.

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
#if os(watchOS)
        case .accessoryCorner:
            CornerWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
#endif
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

                    Text("Start a flight")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
    }
}

#if os(watchOS)
// Corner view (corner complications are watchOS-only, like .widgetLabel)
struct CornerWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        Image(systemName: "wind")
            .font(.system(size: 20, weight: .semibold))
            .widgetLabel {
                Text("Flight")
            }
    }
}
#endif

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
        .description("Shows flight status and quick access")
#if os(watchOS)
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
#else
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
#endif
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
