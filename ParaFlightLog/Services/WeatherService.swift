//
//  WeatherService.swift
//  ParaFlightLog
//
//  Service de récupération des données météo via Open-Meteo API
//  API gratuite sans clé d'API: https://open-meteo.com/
//  Target: iOS only
//

import Foundation
import CoreLocation

// MARK: - Weather Models

/// Conditions météo actuelles
struct CurrentWeather: Codable {
    let temperature: Double           // °C
    let windSpeed: Double             // km/h
    let windDirection: Int            // degrés
    let windGusts: Double?            // km/h
    let weatherCode: Int              // Code WMO
    let cloudCover: Int?              // %
    let humidity: Int?                // %
    let pressure: Double?             // hPa
    let precipitation: Double?        // mm
    let visibility: Double?           // km
    let isDay: Bool

    /// Direction du vent en texte
    var windDirectionText: String {
        let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                          "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((Double(windDirection) + 11.25) / 22.5) % 16
        return directions[index]
    }

    /// Icône SF Symbol pour le code météo
    var weatherIcon: String {
        switch weatherCode {
        case 0: return isDay ? "sun.max.fill" : "moon.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57: return "cloud.sleet.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75: return "cloud.snow.fill"
        case 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// Description du temps
    var weatherDescription: String {
        switch weatherCode {
        case 0: return "Ciel dégagé".localized
        case 1: return "Principalement dégagé".localized
        case 2: return "Partiellement nuageux".localized
        case 3: return "Couvert".localized
        case 45: return "Brouillard".localized
        case 48: return "Brouillard givrant".localized
        case 51, 53, 55: return "Bruine".localized
        case 56, 57: return "Bruine verglaçante".localized
        case 61: return "Pluie légère".localized
        case 63: return "Pluie modérée".localized
        case 65: return "Pluie forte".localized
        case 66, 67: return "Pluie verglaçante".localized
        case 71: return "Neige légère".localized
        case 73: return "Neige modérée".localized
        case 75: return "Neige forte".localized
        case 77: return "Grains de neige".localized
        case 80: return "Averses légères".localized
        case 81: return "Averses modérées".localized
        case 82: return "Averses violentes".localized
        case 85, 86: return "Averses de neige".localized
        case 95: return "Orage".localized
        case 96, 99: return "Orage avec grêle".localized
        default: return "Inconnu".localized
        }
    }

    /// Couleur indicative pour le parapente (vert = bon, rouge = mauvais)
    var flyabilityColor: String {
        // Mauvais si: pluie, neige, orage, brouillard, vent fort
        if weatherCode >= 45 { return "red" }  // Brouillard et précipitations
        if windSpeed > 35 { return "red" }     // Vent trop fort (>35 km/h)
        if windSpeed > 25 { return "orange" }  // Vent modéré-fort
        if windSpeed > 15 { return "yellow" }  // Vent modéré
        return "green"                          // Conditions favorables
    }

    /// Texte d'évaluation pour le vol
    var flyabilityText: String {
        if weatherCode >= 95 { return "Orage - Vol interdit".localized }
        if weatherCode >= 60 { return "Précipitations - Déconseillé".localized }
        if weatherCode >= 45 { return "Visibilité réduite".localized }
        if windSpeed > 35 { return "Vent trop fort".localized }
        if windSpeed > 25 { return "Vent fort - Pilotes expérimentés".localized }
        if windSpeed > 15 { return "Conditions modérées".localized }
        return "Conditions favorables".localized
    }
}

/// Prévision horaire
struct HourlyForecast: Codable, Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let windSpeed: Double
    let windDirection: Int
    let windGusts: Double?
    let weatherCode: Int
    let cloudCover: Int?
    let precipitationProbability: Int?

    var weatherIcon: String {
        let hour = Calendar.current.component(.hour, from: time)
        let isDay = hour >= 7 && hour < 20

        switch weatherCode {
        case 0: return isDay ? "sun.max.fill" : "moon.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 61, 63, 65, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.fill"
        default: return "cloud.fill"
        }
    }

    enum CodingKeys: String, CodingKey {
        case time, temperature, windSpeed, windDirection, windGusts, weatherCode, cloudCover, precipitationProbability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(Date.self, forKey: .time)
        temperature = try container.decode(Double.self, forKey: .temperature)
        windSpeed = try container.decode(Double.self, forKey: .windSpeed)
        windDirection = try container.decode(Int.self, forKey: .windDirection)
        windGusts = try container.decodeIfPresent(Double.self, forKey: .windGusts)
        weatherCode = try container.decode(Int.self, forKey: .weatherCode)
        cloudCover = try container.decodeIfPresent(Int.self, forKey: .cloudCover)
        precipitationProbability = try container.decodeIfPresent(Int.self, forKey: .precipitationProbability)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(windSpeed, forKey: .windSpeed)
        try container.encode(windDirection, forKey: .windDirection)
        try container.encodeIfPresent(windGusts, forKey: .windGusts)
        try container.encode(weatherCode, forKey: .weatherCode)
        try container.encodeIfPresent(cloudCover, forKey: .cloudCover)
        try container.encodeIfPresent(precipitationProbability, forKey: .precipitationProbability)
    }

    init(time: Date, temperature: Double, windSpeed: Double, windDirection: Int, windGusts: Double?, weatherCode: Int, cloudCover: Int?, precipitationProbability: Int?) {
        self.time = time
        self.temperature = temperature
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.windGusts = windGusts
        self.weatherCode = weatherCode
        self.cloudCover = cloudCover
        self.precipitationProbability = precipitationProbability
    }
}

/// Données météo complètes pour un spot
struct SpotWeather {
    let spotId: String?
    let latitude: Double
    let longitude: Double
    let current: CurrentWeather
    let hourlyForecast: [HourlyForecast]
    let fetchedAt: Date

    /// Forecast pour les prochaines heures de vol (8h-18h)
    var flyableHours: [HourlyForecast] {
        let calendar = Calendar.current
        let now = Date()

        return hourlyForecast.filter { forecast in
            let hour = calendar.component(.hour, from: forecast.time)
            return hour >= 8 && hour <= 18 && forecast.time > now
        }
    }

    /// Meilleure fenêtre de vol (heures avec vent < 20 km/h et pas de pluie)
    var bestFlyingWindow: (start: Date, end: Date)? {
        let goodHours = flyableHours.filter { forecast in
            forecast.windSpeed < 25 && forecast.weatherCode < 50
        }

        guard let first = goodHours.first, let last = goodHours.last else {
            return nil
        }

        return (first.time, last.time)
    }
}

// MARK: - Open-Meteo Response Models

private struct OpenMeteoResponse: Codable {
    let latitude: Double
    let longitude: Double
    let current: OpenMeteoCurrent?
    let hourly: OpenMeteoHourly?

    struct OpenMeteoCurrent: Codable {
        let time: String
        let temperature_2m: Double
        let wind_speed_10m: Double
        let wind_direction_10m: Int
        let wind_gusts_10m: Double?
        let weather_code: Int
        let cloud_cover: Int?
        let relative_humidity_2m: Int?
        let surface_pressure: Double?
        let precipitation: Double?
        let is_day: Int
    }

    struct OpenMeteoHourly: Codable {
        let time: [String]
        let temperature_2m: [Double]
        let wind_speed_10m: [Double]
        let wind_direction_10m: [Int]
        let wind_gusts_10m: [Double?]?
        let weather_code: [Int]
        let cloud_cover: [Int?]?
        let precipitation_probability: [Int?]?
    }
}

// MARK: - WeatherService Errors

enum WeatherError: LocalizedError {
    case invalidCoordinates
    case networkError(String)
    case parseError
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidCoordinates:
            return "Coordonnées invalides".localized
        case .networkError(let msg):
            return "Erreur réseau: \(msg)"
        case .parseError:
            return "Erreur de lecture des données météo".localized
        case .noData:
            return "Aucune donnée météo disponible".localized
        }
    }
}

// MARK: - WeatherService

@Observable
final class WeatherService {
    static let shared = WeatherService()

    // MARK: - Properties

    /// Cache des données météo par spot
    private var weatherCache: [String: SpotWeather] = [:]
    private let cacheValidityMinutes: TimeInterval = 30

    /// État de chargement
    private(set) var isLoading = false

    private let baseURL = "https://api.open-meteo.com/v1/forecast"

    private init() {}

    // MARK: - Public Methods

    /// Récupère la météo pour un spot
    func getWeather(for spotId: String, latitude: Double, longitude: Double) async throws -> SpotWeather {
        // Vérifier le cache
        if let cached = weatherCache[spotId],
           Date().timeIntervalSince(cached.fetchedAt) < cacheValidityMinutes * 60 {
            return cached
        }

        return try await fetchWeather(spotId: spotId, latitude: latitude, longitude: longitude)
    }

    /// Récupère la météo pour des coordonnées
    func getWeather(latitude: Double, longitude: Double) async throws -> SpotWeather {
        let cacheKey = "\(latitude),\(longitude)"

        if let cached = weatherCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < cacheValidityMinutes * 60 {
            return cached
        }

        return try await fetchWeather(spotId: nil, latitude: latitude, longitude: longitude)
    }

    /// Force le rafraîchissement de la météo
    func refreshWeather(for spotId: String, latitude: Double, longitude: Double) async throws -> SpotWeather {
        weatherCache.removeValue(forKey: spotId)
        return try await fetchWeather(spotId: spotId, latitude: latitude, longitude: longitude)
    }

    /// Vide le cache
    func clearCache() {
        weatherCache.removeAll()
    }

    // MARK: - Private Methods

    private func fetchWeather(spotId: String?, latitude: Double, longitude: Double) async throws -> SpotWeather {
        guard latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180 else {
            throw WeatherError.invalidCoordinates
        }

        isLoading = true
        defer { isLoading = false }

        // Construire l'URL avec tous les paramètres nécessaires
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,weather_code,cloud_cover,relative_humidity_2m,surface_pressure,precipitation,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,weather_code,cloud_cover,precipitation_probability"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]

        guard let url = components.url else {
            throw WeatherError.invalidCoordinates
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw WeatherError.networkError("Code HTTP invalide")
            }

            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(OpenMeteoResponse.self, from: data)

            let weather = try parseWeatherResponse(apiResponse, spotId: spotId, latitude: latitude, longitude: longitude)

            // Mettre en cache
            let cacheKey = spotId ?? "\(latitude),\(longitude)"
            weatherCache[cacheKey] = weather

            logInfo("Weather fetched for \(cacheKey)", category: .general)
            return weather

        } catch let error as WeatherError {
            throw error
        } catch let error as DecodingError {
            logError("Weather decoding error: \(error)", category: .general)
            throw WeatherError.parseError
        } catch {
            logError("Weather fetch error: \(error.localizedDescription)", category: .general)
            throw WeatherError.networkError(error.localizedDescription)
        }
    }

    private func parseWeatherResponse(_ response: OpenMeteoResponse, spotId: String?, latitude: Double, longitude: Double) throws -> SpotWeather {
        guard let currentData = response.current else {
            throw WeatherError.noData
        }

        let current = CurrentWeather(
            temperature: currentData.temperature_2m,
            windSpeed: currentData.wind_speed_10m,
            windDirection: currentData.wind_direction_10m,
            windGusts: currentData.wind_gusts_10m,
            weatherCode: currentData.weather_code,
            cloudCover: currentData.cloud_cover,
            humidity: currentData.relative_humidity_2m,
            pressure: currentData.surface_pressure,
            precipitation: currentData.precipitation,
            visibility: nil,
            isDay: currentData.is_day == 1
        )

        var hourlyForecast: [HourlyForecast] = []

        if let hourly = response.hourly {
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

            for (index, timeStr) in hourly.time.enumerated() {
                guard index < hourly.temperature_2m.count,
                      index < hourly.wind_speed_10m.count,
                      index < hourly.wind_direction_10m.count,
                      index < hourly.weather_code.count else {
                    continue
                }

                guard let date = dateFormatter.date(from: timeStr) else {
                    continue
                }

                let forecast = HourlyForecast(
                    time: date,
                    temperature: hourly.temperature_2m[index],
                    windSpeed: hourly.wind_speed_10m[index],
                    windDirection: hourly.wind_direction_10m[index],
                    windGusts: hourly.wind_gusts_10m?[index] ?? nil,
                    weatherCode: hourly.weather_code[index],
                    cloudCover: hourly.cloud_cover?[index] ?? nil,
                    precipitationProbability: hourly.precipitation_probability?[index] ?? nil
                )
                hourlyForecast.append(forecast)
            }
        }

        return SpotWeather(
            spotId: spotId,
            latitude: latitude,
            longitude: longitude,
            current: current,
            hourlyForecast: hourlyForecast,
            fetchedAt: Date()
        )
    }
}
