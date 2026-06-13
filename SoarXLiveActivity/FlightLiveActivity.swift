//
//  FlightLiveActivity.swift
//  SoarXLiveActivity
//
//  Live Activity « vol en cours » : écran verrouillé + Dynamic Island.
//

import WidgetKit
import SwiftUI
import ActivityKit

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            // MARK: Écran verrouillé / bannière
            LockScreenFlightView(context: context)
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: Île étendue
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.wingName).font(.caption).lineLimit(1)
                    } icon: {
                        Image(systemName: "paragliding")
                    }
                    .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startDate, style: .timer)
                        .monospacedDigit()
                        .font(.headline)
                        .frame(maxWidth: 64)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let alt = context.state.altitude {
                            metric(icon: "arrow.up.to.line", value: "\(Int(alt)) m")
                        }
                        if let vz = context.state.verticalSpeed {
                            metric(icon: vz >= 0 ? "arrow.up.right" : "arrow.down.right",
                                   value: String(format: "%+.1f m/s", vz),
                                   tint: vz >= 0.2 ? .green : (vz <= -1.0 ? .blue : .secondary))
                        }
                        Spacer()
                        if let spot = context.state.spotName {
                            Label(spot, systemImage: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "paragliding").foregroundStyle(.cyan)
            } compactTrailing: {
                Text(context.state.startDate, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "paragliding").foregroundStyle(.cyan)
            }
            .widgetURL(URL(string: "soarx://flight"))
        }
    }

    private func metric(icon: String, value: String, tint: Color = .primary) -> some View {
        Label(value, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Vue écran verrouillé

private struct LockScreenFlightView: View {
    let context: ActivityViewContext<FlightActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(context.attributes.wingName).font(.subheadline.weight(.semibold)).lineLimit(1)
                } icon: {
                    Image(systemName: "paragliding").foregroundStyle(.cyan)
                }
                if let type = context.attributes.flightType {
                    Text(type).font(.caption2).foregroundStyle(.secondary)
                }
                if let spot = context.state.spotName {
                    Label(spot, systemImage: "mappin.and.ellipse")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(context.state.startDate, style: .timer)
                    .monospacedDigit()
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.cyan)
                HStack(spacing: 10) {
                    if let alt = context.state.altitude {
                        Text("\(Int(alt)) m").font(.caption).foregroundStyle(.secondary)
                    }
                    if let vz = context.state.verticalSpeed {
                        Text(String(format: "%+.1f m/s", vz))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(vz >= 0.2 ? .green : (vz <= -1.0 ? .blue : .secondary))
                    }
                }
            }
        }
        .padding()
    }
}
