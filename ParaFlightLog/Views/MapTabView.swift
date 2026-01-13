//
//  MapTabView.swift
//  ParaFlightLog
//
//  Hub géographique : consolidation de toutes les fonctionnalités map
//  - My Flights (carte des vols)
//  - Live Pilots (pilotes en vol)
//  - NOTAM Zones (restrictions aériennes)
//

import SwiftUI
import MapKit
import SwiftData

struct MapTabView: View {
    @State private var selectedMode: MapMode = .myFlights
    @State private var showingZoneDrawing = false
    @State private var zoneDrawingCenter: CLLocationCoordinate2D?
    @Query private var flights: [Flight]

    enum MapMode: String, CaseIterable {
        case myFlights
        case livePilots
        case spotZones
        case notamZones

        var displayName: String {
            switch self {
            case .myFlights: return String(localized: "Mes vols")
            case .livePilots: return String(localized: "En direct")
            case .spotZones: return String(localized: "Spots")
            case .notamZones: return String(localized: "NOTAM")
            }
        }

        var icon: String {
            switch self {
            case .myFlights: return "map"
            case .livePilots: return "airplane.circle"
            case .spotZones: return "mappin.and.ellipse"
            case .notamZones: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        ZStack {
            // Contenu de la carte selon le mode sélectionné
            Group {
                switch selectedMode {
                case .myFlights:
                    // Réutiliser ChartsView qui contient déjà FlightsSpotsMapView
                    ChartsView()
                case .livePilots:
                    LiveFlightsMapView()
                case .spotZones:
                    SpotZonesMapView(onCreateZone: { coordinate in
                        zoneDrawingCenter = coordinate
                        showingZoneDrawing = true
                    })
                case .notamZones:
                    NOTAMMapView()
                }
            }
            .ignoresSafeArea(edges: .top)

            // Mode selector en bas
            VStack {
                Spacer()

                MapModePicker(selectedMode: $selectedMode)
                    .padding()
            }

            // Floating controls en haut à droite
            VStack(alignment: .trailing, spacing: 12) {
                SettingsGearButton()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .fullScreenCover(isPresented: $showingZoneDrawing) {
            if let center = zoneDrawingCenter {
                ZoneDrawingView(initialCenter: center) { _ in
                    showingZoneDrawing = false
                }
            }
        }
    }
}

// MARK: - MapModePicker

struct MapModePicker: View {
    @Binding var selectedMode: MapTabView.MapMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MapTabView.MapMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedMode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 14, weight: .semibold))

                        if selectedMode == mode {
                            Text(mode.displayName)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundStyle(selectedMode == mode ? .white : .primary)
                    .padding(.horizontal, selectedMode == mode ? 16 : 12)
                    .padding(.vertical, 10)
                    .background {
                        if selectedMode == mode {
                            Color.blue
                        } else {
                            Color(.systemBackground)
                        }
                    }
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(25)
    }
}

// MARK: - SpotZonesMapView

struct SpotZonesMapView: View {
    let onCreateZone: (CLLocationCoordinate2D) -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var approvedZones: [SpotZone] = []
    @State private var pendingZones: [SpotZone] = []
    @State private var isLoading = true
    @State private var selectedZone: SpotZone?
    @State private var showCreateSheet = false
    @State private var longPressLocation: CLLocationCoordinate2D?
    @State private var canDrawZone = false

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    // Approved zones (green)
                    ForEach(approvedZones) { zone in
                        if case .polygon(let coordinates) = zone.geometry {
                            MapPolygon(coordinates: coordinates)
                                .foregroundStyle(.green.opacity(0.2))
                                .stroke(.green, lineWidth: 2)
                        }
                        if case .circle(let center, let radius) = zone.geometry {
                            MapCircle(center: center, radius: radius)
                                .foregroundStyle(.green.opacity(0.2))
                                .stroke(.green, lineWidth: 2)
                        }

                        Annotation(zone.name, coordinate: zone.coordinate) {
                            ZoneMarker(zone: zone, isApproved: true)
                                .onTapGesture {
                                    selectedZone = zone
                                }
                        }
                    }

                    // Pending zones (orange)
                    ForEach(pendingZones) { zone in
                        if case .polygon(let coordinates) = zone.geometry {
                            MapPolygon(coordinates: coordinates)
                                .foregroundStyle(.orange.opacity(0.2))
                                .stroke(.orange, lineWidth: 2)
                        }
                        if case .circle(let center, let radius) = zone.geometry {
                            MapCircle(center: center, radius: radius)
                                .foregroundStyle(.orange.opacity(0.2))
                                .stroke(.orange, lineWidth: 2)
                        }

                        Annotation(zone.name, coordinate: zone.coordinate) {
                            ZoneMarker(zone: zone, isApproved: false)
                                .onTapGesture {
                                    selectedZone = zone
                                }
                        }
                    }

                    // User location
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .realistic))
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            switch value {
                            case .second(true, let drag):
                                if canDrawZone, let location = drag?.location,
                                   let mapCoord = proxy.convert(location, from: .local) {
                                    longPressLocation = mapCoord
                                    showCreateSheet = true
                                }
                            default:
                                break
                            }
                        }
                )
            }

            // Loading indicator
            if isLoading {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
            }

            // Legend and help
            VStack {
                // Legend
                HStack(spacing: 16) {
                    ZoneLegendItem(color: .green, label: "Approuvé")
                    ZoneLegendItem(color: .orange, label: "En vote")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(8)

                Spacer()

                // Create zone button (if eligible)
                if canDrawZone {
                    Text("Appui long pour créer une zone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 120)
        }
        .sheet(item: $selectedZone) { zone in
            ZoneDetailView(zone: zone)
        }
        .sheet(isPresented: $showCreateSheet) {
            if let location = longPressLocation {
                CreateZoneProposalSheet(coordinate: location) { zone in
                    if let zone = zone {
                        pendingZones.append(zone)
                    }
                    showCreateSheet = false
                }
            }
        }
        .task {
            await loadData()
        }
    }

    private func loadData() async {
        isLoading = true

        // Check if user can draw zones
        canDrawZone = await TrustService.shared.canDrawZone()

        // Load approved zones
        do {
            approvedZones = try await SpotZoneService.shared.getApprovedZones()
        } catch {
            approvedZones = []
        }

        // Load pending zones
        do {
            pendingZones = try await SpotZoneService.shared.findPendingZones(near: nil)
        } catch {
            pendingZones = []
        }

        isLoading = false
    }
}

// MARK: - Zone Marker

struct ZoneMarker: View {
    let zone: SpotZone
    let isApproved: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: isApproved ? "mappin.circle.fill" : "mappin.circle")
                .font(.title2)
                .foregroundStyle(isApproved ? .green : .orange)

            Text(zone.name)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .cornerRadius(4)
        }
    }
}

// MARK: - Zone Legend Item

struct ZoneLegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    MapTabView()
}
