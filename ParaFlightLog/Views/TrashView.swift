//
//  TrashView.swift
//  ParaFlightLog
//
//  Deleted flights, recoverable for a week.
//
//  Target: iOS only
//

import SwiftUI
import SwiftData

struct TrashView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \TrashedFlight.deletedAt, order: .reverse) private var trashed: [TrashedFlight]

    @State private var pendingPurge: TrashedFlight?
    @State private var restoreFailed = false

    var body: some View {
        List {
            if trashed.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Deleted flights land here and stay for 7 days, so an accidental delete can be undone.")
                )
            } else {
                Section {
                    ForEach(trashed) { flight in
                        row(flight)
                    }
                } footer: {
                    Text("Flights are removed for good 7 days after deletion.")
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete for good?", isPresented: .constant(pendingPurge != nil)) {
            Button("Delete", role: .destructive) {
                if let pendingPurge { dataController.purgeTrashedFlight(pendingPurge) }
                pendingPurge = nil
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("This flight cannot be recovered afterwards.")
        }
        .alert("Could not restore", isPresented: $restoreFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This flight's saved copy could not be read.")
        }
    }

    private func row(_ flight: TrashedFlight) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(flight.flightDate, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(Self.duration(flight.durationSeconds))
                    if let spot = flight.spotName {
                        Text("• \(spot)").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Inflection markup only resolves in a literal Text — routed
                // through String(localized:) it renders as raw "^[…](inflect:)".
                Group {
                    if flight.daysLeft == 0 {
                        Text("Removed for good today")
                    } else {
                        Text("^[\(flight.daysLeft) day](inflect: true) left")
                    }
                }
                .font(.caption2)
                .foregroundStyle(flight.daysLeft <= 1 ? .orange : .secondary)
            }

            Spacer()

            Button("Restore") {
                if !dataController.restoreFlight(flight) { restoreFailed = true }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingPurge = flight }
        }
    }

    private static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes) min"
    }
}
