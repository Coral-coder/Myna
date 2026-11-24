import CoreLocation
import Foundation
import WeatherKit

/// The weather where the user is, from Apple's WeatherKit, for the assistant.
enum WeatherContext {
    private static let words = [
        "weather", "forecast", "rain", "raining", "snow", "snowing", "temperature", "degrees", "umbrella",
        "jacket", "coat", "cold", "hot", "warm", "humid", "wind", "windy", "storm", "sunny", "cloudy", "outside",
    ]

    static func isWeatherQuestion(_ question: String) -> Bool {
        let lower = question.lowercased()
        return words.contains { lower.contains($0) }
    }

    /// Now, and the next few days, as lines of plain text. Nil if it couldn't be fetched.
    static func summary(at location: CLLocation, place: String) async -> String? {
        guard let weather = try? await WeatherService.shared.weather(for: location) else { return nil }
        let now = weather.currentWeather
        func degrees(_ value: Measurement<UnitTemperature>) -> String {
            value.formatted(.measurement(width: .abbreviated, usage: .weather))
        }
        var lines = ["WEATHER\(place.isEmpty ? "" : " IN \(place.uppercased())") (from Apple Weather, right now):"]
        lines.append("Now: \(now.condition.description), \(degrees(now.temperature)), feels like \(degrees(now.apparentTemperature)), "
                     + "humidity \(Int(now.humidity * 100))%, wind \(now.wind.speed.formatted(.measurement(width: .abbreviated, usage: .general))).")
        for day in weather.dailyForecast.forecast.prefix(4) {
            let name = Calendar.current.isDateInToday(day.date) ? "Today"
                : day.date.formatted(.dateTime.weekday(.wide))
            lines.append("\(name): \(day.condition.description), high \(degrees(day.highTemperature)), low \(degrees(day.lowTemperature)), "
                         + "\(Int(day.precipitationChance * 100))% chance of rain or snow.")
        }
        return lines.joined(separator: "\n")
    }
}
