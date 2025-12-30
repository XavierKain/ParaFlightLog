//
//  SearchViews.swift
//  ParaFlightLog
//
//  Vues de recherche pour vols, pilotes et spots
//  Target: iOS only
//

import SwiftUI

// MARK: - SearchView

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedTab: SearchTab = .flights
    @State private var showingFilters = false

    // Filters
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var minDuration: Int?
    @State private var wingBrand: String = ""

    enum SearchTab: String, CaseIterable {
        case flights = "Vols"
        case pilots = "Pilotes"
        case spots = "Spots"

        var localized: String { rawValue.localized }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Rechercher...".localized, text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding()

                // Tab picker
                Picker("Type", selection: $selectedTab) {
                    ForEach(SearchTab.allCases, id: \.self) { tab in
                        Text(tab.localized).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Filters button (only for flights)
                if selectedTab == .flights {
                    HStack {
                        Button {
                            showingFilters = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "slider.horizontal.3")
                                Text("Filtres".localized)
                                if hasActiveFilters {
                                    Circle()
                                        .fill(.blue)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .font(.subheadline)
                        }

                        Spacer()

                        if hasActiveFilters {
                            Button("Réinitialiser".localized) {
                                clearFilters()
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Content
                switch selectedTab {
                case .flights:
                    SearchFlightsView(
                        searchText: searchText,
                        dateFrom: dateFrom,
                        dateTo: dateTo,
                        minDuration: minDuration,
                        wingBrand: wingBrand
                    )
                case .pilots:
                    SearchPilotsView(searchText: searchText)
                case .spots:
                    SearchSpotsView(searchText: searchText)
                }
            }
            .navigationTitle("Recherche".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer".localized) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                SearchFiltersView(
                    dateFrom: $dateFrom,
                    dateTo: $dateTo,
                    minDuration: $minDuration,
                    wingBrand: $wingBrand
                )
            }
        }
    }

    private var hasActiveFilters: Bool {
        dateFrom != nil || dateTo != nil || minDuration != nil || !wingBrand.isEmpty
    }

    private func clearFilters() {
        dateFrom = nil
        dateTo = nil
        minDuration = nil
        wingBrand = ""
    }
}

// MARK: - SearchFlightsView

struct SearchFlightsView: View {
    let searchText: String
    let dateFrom: Date?
    let dateTo: Date?
    let minDuration: Int?
    let wingBrand: String

    @State private var flights: [PublicFlight] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var hasSearched = false

    var body: some View {
        Group {
            if !hasSearched && searchText.isEmpty && !hasFilters {
                SearchPromptView(message: "Entrez un nom de spot ou de voile".localized)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                ErrorView(message: error) {
                    Task { await search() }
                }
            } else if flights.isEmpty && hasSearched {
                EmptySearchView(message: "Aucun vol trouvé".localized)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(flights) { flight in
                            NavigationLink {
                                PublicFlightDetailView(flightId: flight.id)
                            } label: {
                                PublicFlightCardView(flight: flight)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            Task { await search() }
        }
        .onChange(of: dateFrom) { _, _ in
            Task { await search() }
        }
        .onChange(of: dateTo) { _, _ in
            Task { await search() }
        }
        .onChange(of: minDuration) { _, _ in
            Task { await search() }
        }
        .onChange(of: wingBrand) { _, _ in
            Task { await search() }
        }
    }

    private var hasFilters: Bool {
        dateFrom != nil || dateTo != nil || minDuration != nil || !wingBrand.isEmpty
    }

    private func search() async {
        // Debounce
        try? await Task.sleep(for: .milliseconds(300))

        guard !searchText.isEmpty || hasFilters else {
            flights = []
            hasSearched = false
            return
        }

        isLoading = true
        error = nil
        hasSearched = true

        let query = FlightSearchQuery(
            spotName: searchText.isEmpty ? nil : searchText,
            wingBrand: wingBrand.isEmpty ? nil : wingBrand,
            dateFrom: dateFrom,
            dateTo: dateTo,
            minDurationMinutes: minDuration
        )

        do {
            flights = try await DiscoveryService.shared.searchFlights(query: query)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - SearchPilotsView

struct SearchPilotsView: View {
    let searchText: String

    @State private var pilots: [PilotSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var hasSearched = false

    var body: some View {
        Group {
            if !hasSearched && searchText.isEmpty {
                SearchPromptView(message: "Entrez un nom ou username".localized)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                ErrorView(message: error) {
                    Task { await search() }
                }
            } else if pilots.isEmpty && hasSearched {
                EmptySearchView(message: "Aucun pilote trouvé".localized)
            } else {
                List(pilots) { pilot in
                    NavigationLink {
                        PilotProfileView(pilotId: pilot.id)
                    } label: {
                        PilotSearchRow(pilot: pilot)
                    }
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: searchText) { _, _ in
            Task { await search() }
        }
    }

    private func search() async {
        try? await Task.sleep(for: .milliseconds(300))

        guard !searchText.isEmpty else {
            pilots = []
            hasSearched = false
            return
        }

        isLoading = true
        error = nil
        hasSearched = true

        do {
            pilots = try await DiscoveryService.shared.searchPilots(query: searchText)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - PilotSearchRow

struct PilotSearchRow: View {
    let pilot: PilotSummary

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(pilot.displayName.prefix(1).uppercased())
                        .font(.headline)
                        .foregroundStyle(.blue)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(pilot.displayName)
                    .font(.headline)

                Text("@\(pilot.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - SearchSpotsView

struct SearchSpotsView: View {
    let searchText: String

    @State private var spots: [Spot] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var hasSearched = false

    var body: some View {
        Group {
            if !hasSearched && searchText.isEmpty {
                SearchPromptView(message: "Entrez un nom de spot".localized)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                ErrorView(message: error) {
                    Task { await search() }
                }
            } else if spots.isEmpty && hasSearched {
                EmptySearchView(message: "Aucun spot trouvé".localized)
            } else {
                List(spots) { spot in
                    NavigationLink {
                        SpotDetailView(spotId: spot.id)
                    } label: {
                        SpotListRow(spot: spot)
                    }
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: searchText) { _, _ in
            Task { await search() }
        }
    }

    private func search() async {
        try? await Task.sleep(for: .milliseconds(300))

        guard !searchText.isEmpty else {
            spots = []
            hasSearched = false
            return
        }

        isLoading = true
        error = nil
        hasSearched = true

        do {
            spots = try await SpotService.shared.searchSpots(query: searchText)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - SearchFiltersView

struct SearchFiltersView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var dateFrom: Date?
    @Binding var dateTo: Date?
    @Binding var minDuration: Int?
    @Binding var wingBrand: String

    @State private var showDateFrom = false
    @State private var showDateTo = false

    private let durationOptions = [nil, 15, 30, 60, 120, 180]

    var body: some View {
        NavigationStack {
            Form {
                Section("Période".localized) {
                    Toggle("Date de début".localized, isOn: $showDateFrom)

                    if showDateFrom {
                        DatePicker(
                            "Depuis".localized,
                            selection: Binding(
                                get: { dateFrom ?? Date() },
                                set: { dateFrom = $0 }
                            ),
                            displayedComponents: .date
                        )
                    }

                    Toggle("Date de fin".localized, isOn: $showDateTo)

                    if showDateTo {
                        DatePicker(
                            "Jusqu'à".localized,
                            selection: Binding(
                                get: { dateTo ?? Date() },
                                set: { dateTo = $0 }
                            ),
                            displayedComponents: .date
                        )
                    }
                }

                Section("Durée minimale".localized) {
                    Picker("Durée".localized, selection: $minDuration) {
                        Text("Toutes".localized).tag(nil as Int?)
                        Text("15 min").tag(15 as Int?)
                        Text("30 min").tag(30 as Int?)
                        Text("1 heure").tag(60 as Int?)
                        Text("2 heures").tag(120 as Int?)
                        Text("3 heures").tag(180 as Int?)
                    }
                }

                Section("Voile".localized) {
                    TextField("Marque de voile".localized, text: $wingBrand)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Filtres".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer".localized) {
                        if !showDateFrom { dateFrom = nil }
                        if !showDateTo { dateTo = nil }
                        dismiss()
                    }
                }
            }
            .onAppear {
                showDateFrom = dateFrom != nil
                showDateTo = dateTo != nil
            }
        }
    }
}

// MARK: - Helper Views

struct SearchPromptView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptySearchView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
