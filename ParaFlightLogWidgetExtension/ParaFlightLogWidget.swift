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
            // Au repos : afficher l'icône de l'app
            ZStack {
                AccessoryWidgetBackground()
                Image("WidgetIcon")
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
            }
        }
    }
}

// Vue rectangulaire (pour les complications rectangulaires)
struct RectangularWidgetView: View {
    let entry: FlightEntry

    var body: some View {
        HStack(spacing: 6) {
            // Icône de l'app
            Image("WidgetIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))

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

                    Text("widget_start_flight")
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
        Image("WidgetIcon")
            .resizable()
            .scaledToFit()
            .clipShape(Circle())
            .widgetLabel {
                Text("widget_flight")
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
            Label("ParaFlightLog", systemImage: "timer")
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
        .description("widget_description")
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
