//
//  ZoneDrawingView.swift
//  ParaFlightLog
//
//  Vue pour dessiner une zone polygonale sur la carte
//  Permet de définir précisément les limites d'un spot
//  Target: iOS only
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Zone Drawing View

struct ZoneDrawingView: View {
    @State private var vertices: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isDrawingMode = true
    @State private var showNameSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var areaKm2: Double = 0
    @State private var overlapWarning: String?
    @State private var trustInfo: TrustInfo?

    let initialCenter: CLLocationCoordinate2D
    let onComplete: (SpotZone?) -> Void

    @Environment(\.dismiss) private var dismiss

    private var maxAreaKm2: Double {
        trustInfo?.level.maxZoneAreaKm2 ?? 10
    }

    private var isValidPolygon: Bool {
        vertices.count >= 3 && areaKm2 <= maxAreaKm2 && overlapWarning == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Map
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        // Draw vertices
                        ForEach(Array(vertices.enumerated()), id: \.offset) { index, vertex in
                            Annotation("", coordinate: vertex) {
                                ZoneVertexMarker(
                                    index: index,
                                    isFirst: index == 0,
                                    onDrag: { newCoord in
                                        vertices[index] = newCoord
                                        updateMetrics()
                                    },
                                    onDelete: {
                                        if vertices.count > 3 || vertices.count == index + 1 {
                                            vertices.remove(at: index)
                                            updateMetrics()
                                        }
                                    }
                                )
                            }
                        }

                        // Draw polygon outline
                        if vertices.count >= 2 {
                            MapPolyline(coordinates: vertices + (vertices.count >= 3 ? [vertices[0]] : []))
                                .stroke(.blue, lineWidth: 3)
                        }

                        // Draw filled polygon
                        if vertices.count >= 3 {
                            MapPolygon(coordinates: vertices)
                                .foregroundStyle(.blue.opacity(0.2))
                                .stroke(.blue, lineWidth: 2)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .onTapGesture { screenCoord in
                        if isDrawingMode, let mapCoord = proxy.convert(screenCoord, from: .local) {
                            addVertex(at: mapCoord)
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)

                // Controls overlay
                VStack {
                    Spacer()

                    // Info panel
                    VStack(spacing: 12) {
                        // Area info
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Surface")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(String(format: "%.2f km²", areaKm2))
                                    .font(.headline)
                                    .foregroundStyle(areaKm2 > maxAreaKm2 ? .red : .primary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Points")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("\(vertices.count)")
                                    .font(.headline)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Max")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(String(format: "%.0f km²", maxAreaKm2))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Warnings
                        if areaKm2 > maxAreaKm2 {
                            Label("Zone trop grande", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let warning = overlapWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        // Instructions
                        if vertices.count < 3 {
                            Text("Touchez la carte pour ajouter des points")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isDrawingMode {
                            Text("Continuez ou appuyez sur Terminer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        // Action buttons
                        HStack(spacing: 12) {
                            Button {
                                if !vertices.isEmpty {
                                    vertices.removeLast()
                                    updateMetrics()
                                }
                            } label: {
                                Label("Annuler", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(vertices.isEmpty)

                            Button {
                                vertices.removeAll()
                                areaKm2 = 0
                                overlapWarning = nil
                            } label: {
                                Label("Effacer", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(vertices.isEmpty)

                            Button {
                                isDrawingMode = false
                                showNameSheet = true
                            } label: {
                                Label("Terminer", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isValidPolygon)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("Dessiner une zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                        onComplete(nil)
                    }
                }
            }
            .sheet(isPresented: $showNameSheet) {
                ZoneNameSheet(
                    vertices: vertices,
                    areaKm2: areaKm2,
                    onComplete: { zone in
                        dismiss()
                        onComplete(zone)
                    }
                )
            }
            .alert("Erreur", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .task {
                trustInfo = try? await TrustService.shared.getCurrentUserTrustInfo()
                cameraPosition = .region(MKCoordinateRegion(
                    center: initialCenter,
                    latitudinalMeters: 2000,
                    longitudinalMeters: 2000
                ))
            }
        }
    }

    private func addVertex(at coordinate: CLLocationCoordinate2D) {
        vertices.append(coordinate)
        updateMetrics()
    }

    private func updateMetrics() {
        if vertices.count >= 3 {
            let geometry = SpotZoneGeometry.polygon(coordinates: vertices)
            areaKm2 = geometry.areaKm2

            // Check overlap (simplified - would need actual check)
            Task {
                if let overlap = await checkOverlap() {
                    overlapWarning = "Chevauche \"\(overlap)\""
                } else {
                    overlapWarning = nil
                }
            }
        } else {
            areaKm2 = 0
            overlapWarning = nil
        }
    }

    private func checkOverlap() async -> String? {
        guard vertices.count >= 3 else { return nil }

        let geometry = SpotZoneGeometry.polygon(coordinates: vertices)
        let centroid = geometry.centroid

        // Check if centroid is in any existing zone
        if let existingZone = await SpotZoneService.shared.findMatchingZone(coordinate: centroid) {
            return existingZone.name
        }

        return nil
    }
}

// MARK: - Zone Vertex Marker

struct ZoneVertexMarker: View {
    let index: Int
    let isFirst: Bool
    let onDrag: (CLLocationCoordinate2D) -> Void
    let onDelete: () -> Void

    @State private var isDragging = false

    var body: some View {
        Circle()
            .fill(isFirst ? .green : .blue)
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .stroke(.white, lineWidth: 2)
            }
            .overlay {
                if isFirst {
                    Text("1")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                }
            }
            .shadow(radius: 2)
            .scaleEffect(isDragging ? 1.3 : 1.0)
            .animation(.spring(response: 0.3), value: isDragging)
            .contextMenu {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            }
    }
}

// MARK: - Zone Name Sheet

struct ZoneNameSheet: View {
    let vertices: [CLLocationCoordinate2D]
    let areaKm2: Double
    let onComplete: (SpotZone?) -> Void

    @State private var name = ""
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du spot", text: $name)
                        .autocorrectionDisabled()

                    TextField("Pourquoi ce nom ?", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Informations")
                } footer: {
                    Text("Minimum 20 caractères pour justifier le nom")
                }

                Section {
                    HStack {
                        Text("Points")
                        Spacer()
                        Text("\(vertices.count)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Surface")
                        Spacer()
                        Text(String(format: "%.2f km²", areaKm2))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Zone")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Nommer la zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retour") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Soumettre") {
                        submit()
                    }
                    .disabled(name.count < 3 || reason.count < 20 || isSubmitting)
                }
            }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                let geometry = SpotZoneGeometry.polygon(coordinates: vertices)
                let request = CreateZoneRequest(
                    name: name,
                    geometry: geometry,
                    reason: reason,
                    parentSpotId: nil,
                    photoFileIds: []
                )

                let zone = try await SpotZoneService.shared.createZone(request: request)
                dismiss()
                onComplete(zone)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

// MARK: - Trust Level Badge View

struct TrustLevelBadge: View {
    let level: TrustLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2)

            Text(level.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: level.badgeColor))
        .clipShape(Capsule())
    }

    private var iconName: String {
        switch level {
        case .nouveau: return "person"
        case .actif: return "person.fill"
        case .confirme: return "person.badge.shield.checkmark"
        case .expert: return "star.fill"
        case .moderateur: return "shield.fill"
        }
    }
}
