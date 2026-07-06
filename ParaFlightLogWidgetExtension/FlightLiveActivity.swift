//
//  FlightLiveActivity.swift
//  ParaFlightLogWidgetExtension
//
//  Live Activity UI for phone-tracked flights (Lock Screen banner +
//  Dynamic Island). Uses FlightActivityAttributes from SharedModels.swift,
//  the one source file compiled into both the app and this extension.
//
//  IMPORTANT: this whole file is guarded with os(iOS) — the current widget
//  extension target builds for watchOS (complications), where ActivityKit
//  does not exist. The code activates as soon as this folder is compiled
//  into an iOS widget extension target.
//  Target: Widget Extension (effective on iOS builds only)
//

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Shared formatting helpers

/// Visual language matching the in-app vario readout (TimerViews.swift):
/// green for lift, red for sink, secondary for neutral.
private func varioColor(_ speed: Double) -> Color {
    speed >= 0.1 ? .green : (speed <= -0.1 ? .red : .secondary)
}

private func varioText(_ speed: Double) -> String {
    String(format: "%+.1f m/s", speed)
}

private func varioSymbol(_ speed: Double) -> String {
    speed >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
}

private func altitudeText(_ altitude: Double) -> String {
    "\(Int(altitude)) m"
}

/// Self-ticking timer anchored at the flight start (no pushes needed).
private func flightTimer(startDate: Date) -> Text {
    // Upper bound is only a formatting horizon; flights never last 24 h.
    Text(timerInterval: startDate...startDate.addingTimeInterval(24 * 3600),
         countsDown: false)
}

// MARK: - Lock Screen banner

private struct FlightActivityLockScreenView: View {
    let context: ActivityViewContext<FlightActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // "wind" is the app's paraglider brand symbol everywhere
                Image(systemName: "wind")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.wingName)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(context.state.spotName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                flightTimer(startDate: context.state.startDate)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.trailing)
            }

            if context.state.altitude != nil || context.state.verticalSpeed != nil {
                HStack(spacing: 16) {
                    if let altitude = context.state.altitude {
                        Label(altitudeText(altitude), systemImage: "arrow.up.to.line")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    if let speed = context.state.verticalSpeed {
                        Label(varioText(speed), systemImage: varioSymbol(speed))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(varioColor(speed))
                    }

                    Spacer()

                    Text(context.attributes.flightType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - Live Activity widget

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            // Lock Screen / banner
            FlightActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded presentation
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "wind")
                            .font(.title3)
                            .foregroundStyle(.green)
                        Text(context.attributes.wingName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    flightTimer(startDate: context.state.startDate)
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(.green)
                        .frame(maxWidth: 72)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(context.state.spotName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 20) {
                        if let altitude = context.state.altitude {
                            Label(altitudeText(altitude), systemImage: "arrow.up.to.line")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if let speed = context.state.verticalSpeed {
                            Label(varioText(speed), systemImage: varioSymbol(speed))
                                .font(.callout)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(varioColor(speed))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "wind")
                    .foregroundStyle(.green)
            } compactTrailing: {
                flightTimer(startDate: context.state.startDate)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .frame(maxWidth: 44)
                    .multilineTextAlignment(.trailing)
            } minimal: {
                Image(systemName: "wind")
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}
#endif
