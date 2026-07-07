//
//  SharedFlightDetailView.swift
//  ParaFlightLog
//
//  Lightweight, read-only detail for one community-shared flight, opened
//  from the Explore spot sheet's recent-flights list. There is no local
//  Flight for a community flight and no GPS track is ever shared, so the
//  view is built purely from the shared SUMMARY plus the spot name passed
//  in from the sheet. Presented as a medium-detent sheet by the caller.
//  Target: iOS only
//

import SwiftUI

struct SharedFlightDetailView: View {
    let flight: SharedFlightSummary
    /// Spot name comes from the Explore sheet — `SharedFlightSummary` doesn't
    /// carry it.
    let spotName: String

    @Environment(\.dismiss) private var dismiss

    private var flightType: FlightType? {
        flight.flightType.flatMap(FlightType.init(rawValue:))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    detailRow("Pilot", systemImage: "person.fill") {
                        Text(flight.pilotName)
                    }
                    detailRow("Spot", systemImage: "mappin.circle.fill") {
                        Text(spotName)
                    }
                    detailRow("Date", systemImage: "calendar") {
                        Text(flight.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                            .multilineTextAlignment(.trailing)
                    }
                    detailRow("Duration", systemImage: "clock.fill") {
                        Text(durationText)
                    }
                    if let flightType {
                        detailRow("Type", systemImage: flightType.symbolName) {
                            Text(flightType.rawValue)
                        }
                    }
                } footer: {
                    Text("This is a shared flight summary. Community flights don't include the GPS track.")
                }
            }
            .navigationTitle("Shared flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Icon + label on the left, value on the right (Settings-style row).
    private func detailRow<Value: View>(
        _ label: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
            Spacer()
            value()
                .foregroundStyle(.secondary)
        }
    }

    /// "1h05" / "45 min" from the shared duration.
    private var durationText: String {
        let hours = flight.durationSeconds / 3600
        let minutes = (flight.durationSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(hours)h"
        }
        return "\(minutes) min"
    }
}
