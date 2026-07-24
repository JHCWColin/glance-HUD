import Foundation
import CoreLocation

enum WeatherServiceError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case unexpectedStatusCode(Int)
    case missingTemperature

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Unable to build Open-Meteo URL."
        case .invalidResponse:
            return "Open-Meteo returned an invalid response."
        case .unexpectedStatusCode(let code):
            return "Open-Meteo returned HTTP \(code)."
        case .missingTemperature:
            return "Open-Meteo response did not include a temperature."
        }
    }
}

struct WeatherService {
    func fetchWeather(for coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]

        guard let url = components.url else {
            throw WeatherServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let value = decoded.current?.temperature2M ?? decoded.currentWeather?.temperature

        guard let temperature = value else {
            throw WeatherServiceError.missingTemperature
        }

        return WeatherSnapshot(temperatureCelsius: Int(temperature.rounded()))
    }
}

private struct OpenMeteoResponse: Decodable {
    let current: CurrentBlock?
    let currentWeather: LegacyCurrentWeatherBlock?

    enum CodingKeys: String, CodingKey {
        case current
        case currentWeather = "current_weather"
    }
}

private struct CurrentBlock: Decodable {
    let temperature2M: Double?

    enum CodingKeys: String, CodingKey {
        case temperature2M = "temperature_2m"
    }
}

private struct LegacyCurrentWeatherBlock: Decodable {
    let temperature: Double
}
