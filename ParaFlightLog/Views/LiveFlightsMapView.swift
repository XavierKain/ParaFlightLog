//
//  LiveFlightsMapView.swift
//  ParaFlightLog
//
//  Carte affichant les pilotes actuellement en vol
//  Target: iOS only
//

import SwiftUI
import MapKit

// MARK: - LiveFlightsMapView

struct LiveFlightsMapView: View {
    @State private var liveFlights: [LiveFlight] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedFlight: LiveFlight?
    @State private var cameraPosition: MapCameraPosition = .automatic

    /// Timer pour rafraîchir automatiquement
    @State private var refreshTimer: Timer?

    var body: some View {
        ZStack {
            // Carte
            Map(position: $cameraPosition, selection: $selectedFlight) {
                ForEach(liveFlights) { flight in
                    if let coordinate = flight.coordinate {
                        Annotation(
                            flight.pilotName,
                            coordinate: coordinate,
                            anchor: .bottom
                        ) {
                            LiveFlightMarker(flight: flight, isSelected: selectedFlight?.id == flight.id)
                        }
                        .tag(flight)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            // Overlay: compteur de pilotes en vol
            VStack {
                HStack {
                    Spacer()
                    LiveFlightCountBadge(count: liveFlights.count)
                        .padding()
                }
                Spacer()
            }

            // Overlay: chargement
            if isLoading && liveFlights.isEmpty {
                ProgressView("Chargement des vols en direct...".localized)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Overlay: aucun vol
            if !isLoading && liveFlights.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "airplane.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)

                    Text("Aucun pilote en vol".localized)
                        .font(.headline)

                    Text("Les pilotes en vol apparaîtront ici en temps réel".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .sheet(item: $selectedFlight) { flight in
            LiveFlightDetailSheet(flight: flight)
                .presentationDetents([.medium])
        }
        .navigationTitle("Vols en direct".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await refreshFlights()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task {
            await refreshFlights()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    // MARK: - Private Methods

    private func refreshFlights() async {
        isLoading = true
        errorMessage = nil

        do {
            liveFlights = try await LiveFlightService.shared.fetchLiveFlights()

            // Centrer la carte sur les vols si présents
            if let firstFlight = liveFlights.first,
               let coordinate = firstFlight.coordinate {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
                ))
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task {
                await refreshFlights()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - LiveFlightMarker

struct LiveFlightMarker: View {
    let flight: LiveFlight
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            // Avatar ou initiales
            ZStack {
                Circle()
                    .fill(isSelected ? Color.blue : Color.orange)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                if let photoId = flight.pilotPhotoFileId {
                    ProfilePhotoView(fileId: photoId, displayName: flight.pilotName, size: 40)
                } else {
                    Text(flight.pilotName.prefix(1).uppercased())
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }

                // Indicateur "en vol"
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().stroke(Color.white, lineWidth: 2)
                    )
                    .offset(x: 16, y: -16)
            }

            // Durée du vol
            Text(flight.formattedDuration)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.7))
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }
}

// MARK: - LiveFlightCountBadge

struct LiveFlightCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(count > 0 ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text("\(count)")
                .font(.headline)
                .fontWeight(.bold)

            Text(count == 1 ? "pilote en vol".localized : "pilotes en vol".localized)
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - LiveFlightDetailSheet

struct LiveFlightDetailSheet: View {
    let flight: LiveFlight
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header pilote
                HStack(spacing: 16) {
                    if let photoId = flight.pilotPhotoFileId {
                        ProfilePhotoView(fileId: photoId, displayName: flight.pilotName, size: 60)
                    } else {
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 60, height: 60)
                            .overlay {
                                Text(flight.pilotName.prefix(1).uppercased())
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.blue)
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(flight.pilotName)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("@\(flight.pilotUsername)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Badge "En vol"
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("En vol".localized)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
                }
                .padding()

                Divider()

                // Stats du vol
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(
                        icon: "clock.fill",
                        value: flight.formattedDuration,
                        label: "Durée".localized
                    )

                    if let altitude = flight.altitude {
                        StatCard(
                            icon: "arrow.up",
                            value: "\(Int(altitude))m",
                            label: "Altitude".localized
                        )
                    } else {
                        StatCard(
                            icon: "arrow.up",
                            value: "—",
                            label: "Altitude".localized
                        )
                    }

                    if let spotName = flight.spotName {
                        StatCard(
                            icon: "mappin",
                            value: spotName,
                            label: "Spot".localized
                        )
                    } else {
                        StatCard(
                            icon: "mappin",
                            value: "—",
                            label: "Spot".localized
                        )
                    }
                }
                .padding(.horizontal)

                // Voile
                if let wingName = flight.wingName {
                    HStack {
                        Image(systemName: "wind")
                            .foregroundStyle(.blue)
                        Text(wingName)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Vol en direct".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)

            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Previews

#Preview {
    NavigationStack {
        LiveFlightsMapView()
    }
}
