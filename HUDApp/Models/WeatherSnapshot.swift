import Foundation

struct WeatherSnapshot: Sendable {
    let temperatureCelsius: Int

    var hudText: String {
        "\(temperatureCelsius)C"
    }

    var displayText: String {
        "\(temperatureCelsius)\u{00B0}C"
    }
}
