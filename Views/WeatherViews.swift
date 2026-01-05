//
//  WeatherViews.swift
//  ParaFlightLog
//
//  Composants UI pour afficher les données météo
//  - Widget météo compact
//  - Vue météo détaillée
//  - Prévisions horaires
//  Target: iOS only
//

import SwiftUI
import CoreLocation

// MARK: - SpotWeatherWidget

/// Widget météo compact pour intégration dans SpotDetailView
struct SpotWeatherWidget: View {
    let latitude: Double
    let longitude: Double
    let spotId: String?

    @State private var weather: SpotWeather?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingDetailedWeather = false

    init(latitude: Double, longitude: Double, spotId: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.spotId = spotId
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Météo".localized, systemImage: "cloud.sun.fill")
                    .font(.headline)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        showingDetailedWeather = true
                    } label: {
                        Text("Détails".localized)
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if let weather = weather {
                currentWeatherView(weather.current)
            } else if isLoading {
                ProgressView()
                    .padding()
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await loadWeather()
        }
        .sheet(isPresented: $showingDetailedWeather) {
            if let weather = weather {
                DetailedWeatherView(weather: weather)
            }
        }
    }

    @ViewBuilder
    private func currentWeatherView(_ current: CurrentWeather) -> some View {
        VStack(spacing: 12) {
            // Température et icône
            HStack(spacing: 16) {
                // Icône météo
                Image(systemName: current.weatherIcon)
                    .font(.system(size: 40))
                    .foregroundStyle(weatherIconColor(current.weatherCode))

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(current.temperature))°C")
                        .font(.system(size: 28, weight: .bold))

                    Text(current.weatherDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Indicateur volabilité
                VStack(spacing: 4) {
                    Circle()
                        .fill(flyabilityColor(current))
                        .frame(width: 16, height: 16)

                    Text(current.flyabilityText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(width: 80)
            }
            .padding(.horizontal)

            Divider()

            // Stats vent
            HStack(spacing: 20) {
                WeatherStatItem(
                    icon: "wind",
                    value: "\(Int(current.windSpeed))",
                    unit: "km/h",
                    label: "Vent".localized
                )

                WeatherStatItem(
                    icon: "safari",
                    value: current.windDirectionText,
                    unit: "°",
                    label: "Direction".localized
                )

                if let gusts = current.windGusts {
                    WeatherStatItem(
                        icon: "wind.circle",
                        value: "\(Int(gusts))",
                        unit: "km/h",
                        label: "Rafales".localized
                    )
                }

                if let cloudCover = current.cloudCover {
                    WeatherStatItem(
                        icon: "cloud.fill",
                        value: "\(cloudCover)",
                        unit: "%",
                        label: "Nuages".localized
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func loadWeather() async {
        isLoading = true
        errorMessage = nil

        do {
            if let spotId = spotId {
                weather = try await WeatherService.shared.getWeather(
                    for: spotId,
                    latitude: latitude,
                    longitude: longitude
                )
            } else {
                weather = try await WeatherService.shared.getWeather(
                    latitude: latitude,
                    longitude: longitude
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func weatherIconColor(_ code: Int) -> Color {
        switch code {
        case 0: return .yellow
        case 1, 2: return .orange
        case 3: return .gray
        case 45, 48: return .gray
        case 51...67: return .blue
        case 71...77, 85, 86: return .cyan
        case 80...82: return .blue
        case 95...99: return .purple
        default: return .gray
        }
    }

    private func flyabilityColor(_ current: CurrentWeather) -> Color {
        switch current.flyabilityColor {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        default: return .gray
        }
    }
}

// MARK: - WeatherStatItem

struct WeatherStatItem: View {
    let icon: String
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)

            HStack(spacing: 2) {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - DetailedWeatherView

/// Vue détaillée de la météo avec prévisions
struct DetailedWeatherView: View {
    let weather: SpotWeather

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Conditions actuelles
                    currentConditionsCard

                    // Fenêtre de vol recommandée
                    if let window = weather.bestFlyingWindow {
                        flyingWindowCard(window)
                    }

                    // Prévisions horaires
                    hourlyForecastSection

                    // Légende
                    legendSection
                }
                .padding()
            }
            .navigationTitle("Météo détaillée".localized)
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

    private var currentConditionsCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Conditions actuelles".localized)
                    .font(.headline)
                Spacer()
                Text(weather.fetchedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                // Grande icône météo
                VStack(spacing: 8) {
                    Image(systemName: weather.current.weatherIcon)
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)

                    Text(weather.current.weatherDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Stats
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "thermometer")
                        Text("\(Int(weather.current.temperature))°C")
                            .font(.title2)
                            .fontWeight(.bold)
                    }

                    HStack {
                        Image(systemName: "wind")
                        Text("\(Int(weather.current.windSpeed)) km/h \(weather.current.windDirectionText)")
                    }

                    if let gusts = weather.current.windGusts {
                        HStack {
                            Image(systemName: "wind.circle")
                            Text("Rafales: \(Int(gusts)) km/h".localized)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let humidity = weather.current.humidity {
                        HStack {
                            Image(systemName: "humidity")
                            Text("Humidité: \(humidity)%".localized)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)

                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func flyingWindowCard(_ window: (start: Date, end: Date)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.green)
                Text("Fenêtre de vol recommandée".localized)
                    .font(.headline)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("De".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(window.start, format: .dateTime.hour().minute())
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                Spacer()

                VStack(alignment: .trailing) {
                    Text("À".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(window.end, format: .dateTime.hour().minute())
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var hourlyForecastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prévisions horaires".localized)
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(weather.hourlyForecast.prefix(24))) { forecast in
                        HourlyForecastItem(forecast: forecast)
                    }
                }
            }
        }
    }

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Légende volabilité".localized)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                LegendItem(color: .green, text: "Bon".localized)
                LegendItem(color: .yellow, text: "Modéré".localized)
                LegendItem(color: .orange, text: "Difficile".localized)
                LegendItem(color: .red, text: "Dangereux".localized)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - HourlyForecastItem

struct HourlyForecastItem: View {
    let forecast: HourlyForecast

    var body: some View {
        VStack(spacing: 8) {
            Text(forecast.time, format: .dateTime.hour())
                .font(.caption)
                .foregroundStyle(.secondary)

            Image(systemName: forecast.weatherIcon)
                .font(.title2)
                .foregroundStyle(iconColor)

            Text("\(Int(forecast.temperature))°")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 2) {
                Image(systemName: "wind")
                    .font(.caption2)
                Text("\(Int(forecast.windSpeed))")
                    .font(.caption)
            }
            .foregroundStyle(windColor)

            if let precipProb = forecast.precipitationProbability, precipProb > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.caption2)
                    Text("\(precipProb)%")
                        .font(.caption2)
                }
                .foregroundStyle(.blue)
            }
        }
        .frame(width: 60)
        .padding(.vertical, 8)
        .background(flyabilityBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var iconColor: Color {
        switch forecast.weatherCode {
        case 0: return .yellow
        case 1, 2: return .orange
        case 3: return .gray
        case 45...99: return .blue
        default: return .gray
        }
    }

    private var windColor: Color {
        if forecast.windSpeed > 35 { return .red }
        if forecast.windSpeed > 25 { return .orange }
        if forecast.windSpeed > 15 { return .yellow }
        return .primary
    }

    private var flyabilityBackground: Color {
        if forecast.weatherCode >= 50 { return .red.opacity(0.1) }
        if forecast.windSpeed > 35 { return .red.opacity(0.1) }
        if forecast.windSpeed > 25 { return .orange.opacity(0.1) }
        if forecast.windSpeed > 15 { return .yellow.opacity(0.1) }
        return .green.opacity(0.1)
    }
}

// MARK: - LegendItem

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
        }
    }
}

// MARK: - Compact Weather Row (for spot list)

struct SpotWeatherRow: View {
    let latitude: Double
    let longitude: Double

    @State private var weather: CurrentWeather?
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else if let weather = weather {
                Image(systemName: weather.weatherIcon)
                    .foregroundStyle(.blue)

                Text("\(Int(weather.temperature))°")

                Image(systemName: "wind")
                    .font(.caption2)
                Text("\(Int(weather.windSpeed))")
                    .font(.caption)

                Circle()
                    .fill(flyabilityColor(weather))
                    .frame(width: 8, height: 8)
            } else {
                Text("--")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task {
            await loadWeather()
        }
    }

    private func loadWeather() async {
        isLoading = true
        do {
            let spotWeather = try await WeatherService.shared.getWeather(
                latitude: latitude,
                longitude: longitude
            )
            weather = spotWeather.current
        } catch {
            weather = nil
        }
        isLoading = false
    }

    private func flyabilityColor(_ weather: CurrentWeather) -> Color {
        switch weather.flyabilityColor {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        default: return .gray
        }
    }
}

// MARK: - Previews

#Preview("Weather Widget") {
    SpotWeatherWidget(
        latitude: 45.9,
        longitude: 6.1
    )
    .padding()
}

#Preview("Weather Row") {
    SpotWeatherRow(latitude: 45.9, longitude: 6.1)
}
