//
//  NearbySpotsView.swift
//  ParaFlightLog
//
//  "Report conditions near me" (reached from the Home screen): a sheet that
//  finds the pilot's location, lists LOCAL spots sorted by distance with each
//  spot's live consensus, and — when nothing is close — lets the pilot drop a
//  new spot at their current position and report on it immediately.
//
//  Everything is fail-soft: a denied/unavailable location falls back to all
//  spots sorted by name; a missing consensus / unconfigured backend just
//  renders nothing extra.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import CoreLocation

struct NearbySpotsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Spot.name) private var spots: [Spot]

    /// How the pilot's location resolved. Drives the header hint and whether a
    /// new spot can be created (creation needs a real fix).
    private enum LocationState: Equatable {
        case requesting
        case resolved
        /// Permission denied or restricted — offer all spots by name.
        case denied
        /// Permission granted but no fix (timeout / hardware) — all spots by name.
        case unavailable
    }

    @State private var locationState: LocationState = .requesting
    @State private var coordinate: CLLocationCoordinate2D?

    /// Report sheet target (existing spot or a just-created one).
    @State private var reportTarget: ReportTarget?
    /// Which spot to push (its full detail page).
    @State private var pushedSpot: Spot?

    /// Draft name for a brand-new spot at the current location.
    @State private var newSpotName: String = ""
    /// Bumped after a report sheet dismisses so visible consensus labels reload.
    @State private var refreshToken = 0

    /// A spot counts as "near" within this radius; beyond it we nudge the pilot
    /// to create a new spot instead.
    private static let nearRadiusMeters: Double = 2000
    private static let listCap = 15

    var body: some View {
        NavigationStack {
            List {
                if let hint = locationHint {
                    Section {
                        Label(hint, systemImage: locationState == .requesting ? "location" : "location.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                spotsSection
                createSection
            }
            .navigationTitle("Report near me")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $pushedSpot) { spot in
                SpotDetailView(spot: spot)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $reportTarget, onDismiss: { refreshToken += 1 }) { target in
                ConditionReportSheet(spot: target.spot, spotKey: target.spotKey, spotName: target.spotName)
            }
        }
        .task { resolveLocation() }
        .onChange(of: locationService.authorizationStatus) { _, _ in
            resolveLocation()
        }
    }

    // MARK: - Nearby spots

    /// The rows to show: distance-sorted when we have a fix, otherwise all local
    /// spots by name (capped) with no distance.
    private var rows: [NearbyRow] {
        if let coordinate, locationState == .resolved {
            return ConditionReportService.shared
                .nearbySpots(from: coordinate, spots: spots, limit: Self.listCap)
                .map { NearbyRow(spot: $0.spot, distanceMeters: $0.distanceMeters) }
        }
        return spots.prefix(Self.listCap).map { NearbyRow(spot: $0, distanceMeters: nil) }
    }

    /// True when no located spot sits within `nearRadiusMeters` — the moment to
    /// emphasize "create a new spot here".
    private var nothingNearby: Bool {
        guard locationState == .resolved else { return spots.isEmpty }
        return !rows.contains { ($0.distanceMeters ?? .greatestFiniteMagnitude) <= Self.nearRadiusMeters }
    }

    @ViewBuilder
    private var spotsSection: some View {
        let currentRows = rows
        if !currentRows.isEmpty {
            Section {
                ForEach(currentRows) { row in
                    NearbySpotRow(
                        row: row,
                        refreshToken: refreshToken,
                        onOpen: { pushedSpot = row.spot },
                        onReport: { startReport(for: row.spot) }
                    )
                }
            } header: {
                Text(coordinate != nil && locationState == .resolved ? "Spots near you" : "Your spots")
            }
        }
    }

    // MARK: - Create a new spot

    @ViewBuilder
    private var createSection: some View {
        Section {
            TextField("New spot name", text: $newSpotName)
                .textInputAutocapitalization(.words)

            Button {
                createSpotAndReport()
            } label: {
                Label("Create a new spot here", systemImage: "mappin.and.ellipse")
                    .fontWeight(nothingNearby ? .semibold : .regular)
            }
            .disabled(!canCreate)
        } header: {
            Text("New spot")
        } footer: {
            if coordinate == nil {
                Text("A location fix is needed to place a new spot at where you are.")
            } else if nothingNearby {
                Text("No spot within \(Int(Self.nearRadiusMeters / 1000)) km — drop one at your current location and report on it.")
            } else {
                Text("Not here yet? Add this launch at your current location.")
            }
        }
    }

    /// Create needs a trimmed name AND a real location fix (coordinates come
    /// from the pilot's position, per the brief).
    private var canCreate: Bool {
        coordinate != nil && !newSpotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createSpotAndReport() {
        guard let coordinate else { return }
        let name = newSpotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let spot = dataController.findOrCreateSpot(named: name, city: nil, coordinate: coordinate)
        // Give it a community key so its reports match across users (findOrCreate
        // may return a pre-existing spot that never got shared).
        if spot.communitySpotKey == nil,
           let key = CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude) {
            spot.communitySpotKey = key
        }
        _ = dataController.saveContext()

        newSpotName = ""
        startReport(for: spot)
    }

    // MARK: - Report

    /// Opens the report sheet for a spot, deriving its community key when the
    /// spot hasn't been shared yet. No coordinates → no key → no-op (fail-soft).
    private func startReport(for spot: Spot) {
        guard let key = spot.communitySpotKey
                ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude) else {
            return
        }
        reportTarget = ReportTarget(spot: spot, spotKey: key, spotName: spot.name)
    }

    // MARK: - Location

    private func resolveLocation() {
        switch locationService.authorizationStatus {
        case .notDetermined:
            locationState = .requesting
            locationService.requestAuthorization()
            // The onChange(authorizationStatus) handler re-enters once resolved.
        case .denied, .restricted:
            locationState = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            requestFix()
        @unknown default:
            locationState = .unavailable
        }
    }

    private func requestFix() {
        locationService.requestLocation { location in
            // Hop to main for the state mutation (mirrors TimerViews' spot
            // detection); the service's callbacks already run there.
            let fix = location?.coordinate ?? locationService.lastKnownLocation?.coordinate
            DispatchQueue.main.async {
                if let fix {
                    coordinate = fix
                    locationState = .resolved
                } else {
                    locationState = .unavailable
                }
            }
        }
    }

    private var locationHint: String? {
        switch locationState {
        case .requesting:
            return "Finding spots near you…"
        case .resolved:
            return nil
        case .denied:
            return "Location is off — showing all your spots. Enable location in Settings to sort by distance."
        case .unavailable:
            return "Couldn't get your location — showing all your spots by name."
        }
    }
}

// MARK: - Row model

private struct NearbyRow: Identifiable {
    let spot: Spot
    let distanceMeters: Double?
    var id: UUID { spot.id }
}

/// Report-sheet target: an existing or freshly-created spot plus its key/name.
private struct ReportTarget: Identifiable {
    let id = UUID()
    let spot: Spot?
    let spotKey: String
    let spotName: String
}

// MARK: - Spot row

/// One spot row: name + distance + live consensus, with a tap target for the
/// full detail page and a dedicated "Report" action.
private struct NearbySpotRow: View {
    let row: NearbyRow
    let refreshToken: Int
    let onOpen: () -> Void
    let onReport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.spot.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)

                HStack(spacing: 6) {
                    if let distance = row.distanceMeters {
                        Label(Self.distanceLabel(distance), systemImage: "location.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let city = row.spot.city, !city.isEmpty {
                        Text(city)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                RowConsensusView(spot: row.spot, refreshToken: refreshToken)
            }
            // Whole info block pushes the spot detail; kept separate from the
            // Report button so the two tap targets never collide.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            Button(action: onReport) {
                Label("Report", systemImage: "megaphone.fill")
                    .labelStyle(.iconOnly)
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.teal)
            .accessibilityLabel("Report conditions at \(row.spot.name)")
        }
        .padding(.vertical, 2)
    }

    /// "850 m" under a km, "1.2 km" above.
    private static func distanceLabel(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }
}

// MARK: - Per-row consensus

/// Loads this spot's freshest consensus for the row. Renders nothing when
/// there are no reports or the backend isn't configured (fail-soft).
private struct RowConsensusView: View {
    let spot: Spot
    let refreshToken: Int

    @State private var consensus: ReportConsensus?

    private var spotKey: String? {
        spot.communitySpotKey
            ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
    }

    var body: some View {
        Group {
            if let consensus {
                HStack(spacing: 5) {
                    Text(consensus.latest.status.emoji)
                        .font(.caption2)
                    Text(consensus.latest.status.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(consensus.latest.status.color)
                    if consensus.concurringCount > 1 {
                        Text("· \(consensus.concurringCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: "\(spotKey ?? "")-\(refreshToken)") {
            await load()
        }
    }

    private func load() async {
        guard let spotKey else { consensus = nil; return }
        let reports = try? await ConditionReportService.shared.recentReports(forSpotKey: spotKey)
        consensus = reports?.consensus
    }
}
