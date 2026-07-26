//
//  SpotInsightsViews.swift
//  ParaFlightLog
//
//  Surfr-inspired spot insights (playbook §8):
//  - SpotRecordsSection: the pilot's records at this spot (2×2 stat tiles).
//  - HourlyForecastStrip: horizontally scrolling 48 h forecast, one compact
//    cell per hour tinted by flyability against the launch directions.
//  - SpotClimatologySection: "best months to fly" — monthly wind-band bars +
//    flyable-day share from 3 years of ERA5 reanalysis (ClimatologyService).
//  All sections fail soft and hide themselves when they have nothing to show.
//  Target: iOS only
//

import SwiftUI

// MARK: - SpotRecordsSection (my records at this spot)

/// The pilot's personal records at one spot, from their LOCAL flights:
/// longest flight, max altitude, max speed, total hours. Tiles without data
/// are dropped; the whole section hides when there are no flights.
struct SpotRecordsSection: View {
    let spot: Spot

    private struct Record: Identifiable {
        let id: String
        let label: String
        let value: String
        let symbol: String
    }

    private var flights: [Flight] { spot.flights ?? [] }

    private var records: [Record] {
        guard !flights.isEmpty else { return [] }
        var result: [Record] = []

        if let longest = flights.max(by: { $0.durationSeconds < $1.durationSeconds }),
           longest.durationSeconds > 0 {
            result.append(Record(id: "longest", label: "Longest flight",
                                 value: Self.durationText(longest.durationSeconds),
                                 symbol: "clock.fill"))
        }
        let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
        if totalSeconds > 0 {
            result.append(Record(id: "hours", label: "Total airtime",
                                 value: Self.hoursText(totalSeconds),
                                 symbol: "sum"))
        }
        if let maxAltitude = flights.compactMap(\.maxAltitude).max() {
            result.append(Record(id: "altitude", label: "Max altitude",
                                 value: "\(Int(maxAltitude.rounded())) m",
                                 symbol: "arrow.up.to.line"))
        }
        if let maxSpeed = flights.compactMap(\.maxSpeed).max() {
            // Ground speed is stored in m/s.
            result.append(Record(id: "speed", label: "Max speed",
                                 value: "\(Int((maxSpeed * 3.6).rounded())) km/h",
                                 symbol: "speedometer"))
        }
        return result
    }

    var body: some View {
        if !records.isEmpty {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(records) { record in
                        VStack(spacing: 4) {
                            Image(systemName: record.symbol)
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text(record.value)
                                .font(.title3.weight(.bold).monospacedDigit())
                            Text(record.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            } header: {
                Text("My records here")
            }
        }
    }

    private static func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes) min"
    }

    private static func hoursText(_ seconds: Int) -> String {
        // Under an hour this printed "0.0 h" right next to a "Longest flight
        // 2 min" tile, reading as "you have never flown here". Below the hour,
        // fall back to the same minute idiom the other tiles use.
        guard seconds >= 3600 else { return durationText(seconds) }
        let hours = Double(seconds) / 3600
        return hours >= 10 ? "\(Int(hours.rounded())) h" : String(format: "%.1f h", hours)
    }
}

// MARK: - HourlyForecastStrip (48 h, colored by flyability)

/// Horizontally scrolling strip of hourly forecast cells: hour, wind value
/// tinted by flyability against the launch directions, gusts, direction
/// arrow, temperature. Day changes get a weekday separator label.
struct HourlyForecastStrip: View {
    let hours: [HourForecast]
    /// The spot's launch directions — drives the per-hour flyability tint.
    let directions: [String]

    @AppStorage(WindUnit.storageKey) private var windUnit: WindUnit = .kmh

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                    if index == 0 || isNewDay(at: index) {
                        dayLabel(hour.time)
                    }
                    cell(hour)
                }
            }
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
    }

    private func isNewDay(at index: Int) -> Bool {
        guard index > 0 else { return false }
        return !Calendar.current.isDate(hours[index].time, inSameDayAs: hours[index - 1].time)
    }

    private func dayLabel(_ date: Date) -> some View {
        Text(date, format: .dateTime.weekday(.abbreviated))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            // No maxHeight:.infinity — inside a horizontal ScrollView the height
            // is content-driven, so stretching this label makes the strip's
            // height ambiguous and it collapses to 0 on the first layout pass
            // (the "1206×0 image slot" / CAMetalLayer 0×0 spam). Top alignment
            // (the HStack's) already seats it against the taller cells.
            .padding(.horizontal, 2)
    }

    private func cell(_ hour: HourForecast) -> some View {
        let rating = WeatherService.flyability(
            windDirectionDeg: hour.windDirectionDeg,
            windSpeed: hour.windSpeed,
            windGusts: hour.windGusts,
            spotDirections: directions
        )
        let tint = rating == .unknown ? Color(.systemGray4) : rating.displayColor

        return VStack(spacing: 3) {
            Text(hour.time, format: .dateTime.hour())
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(windText(hour.windSpeed))
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 30)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(tint, in: RoundedRectangle(cornerRadius: 6))

            Text(windText(hour.windGusts))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            if let direction = hour.windDirectionDeg {
                // Wind comes FROM `direction`; the arrow shows where it blows TO.
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(direction + 180))
            }

            if let temperature = hour.temperature {
                Text("\(Int(temperature.rounded()))°")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Wind value in the pilot's unit (km/h values from Open-Meteo).
    private func windText(_ kmh: Double?) -> String {
        guard let kmh else { return "—" }
        switch windUnit {
        case .kmh: return "\(Int(kmh.rounded()))"
        case .knots: return "\(Int((kmh / WindUnit.kmhPerKnot).rounded()))"
        }
    }
}

// MARK: - SpotClimatologySection ("best months to fly")

/// Monthly wind climatology for a located spot: one stacked bar per month
/// (share of days per wind band of the daily max) plus the share of
/// flyable-looking days given the launch directions. Data from 3 years of
/// ERA5 reanalysis, cached 30 days (ClimatologyService). Hides itself until
/// loaded; failures keep it hidden (fail-soft).
struct SpotClimatologySection: View {
    let latitude: Double
    let longitude: Double
    /// Launch directions for the flyable-share column (empty = column hidden).
    let directions: [String]

    private enum LoadState {
        case loading
        case loaded([MonthClimatology])
        /// Fetch failed (or in flight elsewhere): render nothing, fail soft.
        case hidden
    }

    @State private var state: LoadState = .loading

    /// Wind bands of the daily max: [<10, 10–20, 20–30, 30–40, ≥40] km/h.
    private static let bandColors: [Color] = [
        Color(.systemGray4), .green, .yellow, .orange, .red
    ]
    private static let monthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        default:
            section
        }
    }

    private var section: some View {
        Section {
            switch state {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Computing climatology…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let months):
                ForEach(months) { month in
                    monthRow(month)
                }
                legend
            case .hidden:
                EmptyView()
            }
        } header: {
            Text("Best months to fly")
                // On the header (a plain view), NOT on the Section — same
                // pattern as the other spot-page sections.
                .task { await load() }
        } footer: {
            if case .loaded = state {
                Text(directions.isEmpty
                     ? "Share of days per wind band (daily max, last 3 years — ERA5 via Open-Meteo). Set launch directions to see the flyable-day share."
                     : "Bars: share of days per wind band (daily max). %: days with 10–35 km/h from the launch directions. Last 3 years, ERA5 via Open-Meteo.")
            }
        }
    }

    private func monthRow(_ month: MonthClimatology) -> some View {
        HStack(spacing: 10) {
            Text(Self.monthLabels[month.month - 1])
                .font(.caption.weight(.medium))
                .frame(width: 30, alignment: .leading)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(month.bandShares.enumerated()), id: \.offset) { index, share in
                        Rectangle()
                            .fill(Self.bandColors[index])
                            .frame(width: max(0, geo.size.width * share))
                    }
                }
                .clipShape(Capsule())
                .background(Capsule().fill(Color(.systemGray5)))
            }
            .frame(height: 10)

            if let share = month.flyableShare(directions: directions) {
                Text("\(Int((share * 100).rounded())) %")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(shareColor(share))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(month))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(Self.bandColors[0], "<10")
            legendItem(Self.bandColors[1], "10–20")
            legendItem(Self.bandColors[2], "20–30")
            legendItem(Self.bandColors[3], "30–40")
            legendItem(Self.bandColors[4], "40+ km/h")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    /// Green ≥ 50 %, orange ≥ 25 %, secondary below.
    private func shareColor(_ share: Double) -> Color {
        if share >= 0.5 { return .green }
        if share >= 0.25 { return .orange }
        return .secondary
    }

    private func accessibilityText(_ month: MonthClimatology) -> String {
        var text = Self.monthLabels[month.month - 1]
        if let share = month.flyableShare(directions: directions) {
            text += ", \(Int((share * 100).rounded())) percent flyable days"
        }
        return text
    }

    private func load() async {
        if case .loaded = state { return }
        do {
            if let months = try await ClimatologyService.shared.climatology(
                latitude: latitude, longitude: longitude
            ), months.contains(where: { $0.dayCount > 0 }) {
                state = .loaded(months)
            } else {
                state = .hidden
            }
        } catch {
            logInfo("Climatology unavailable: \(error.localizedDescription)", category: .weather)
            state = .hidden
        }
    }
}
