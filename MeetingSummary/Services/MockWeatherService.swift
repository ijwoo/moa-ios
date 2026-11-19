#if DEBUG
import Foundation

/// 개발용 가상 날씨 (화면 확인과 테스트용). 위치를 묻지 않고 밖으로 나가지도 않는다. 값은 모두 지어낸 것이다.
///
/// - 아는 도시 이름이면 그 도시의 가상 날씨, 모르는 이름이면 "찾지 못함"
/// - 지역이 없으면(지금 위치) 가상 날씨. `locationDenied`를 켜면 위치 권한이 없는 기기처럼 답한다
struct MockWeatherService: WeatherProviding {
    /// 가짜 맥이 말에서 알아듣는 도시
    static let places = ["서울", "부산", "제주", "대구", "인천", "광주", "대전", "강릉", "도쿄"]

    var locationDenied = false
    var now: @Sendable () -> Date = { .now }

    /// 실행 인자 `-demoWeather denied`: 위치 권한이 없는 기기. `-demoWeather real`: 가짜 맥과 함께 실제 날씨를 쓴다 (nil을 돌려준다)
    static func fromArguments() -> MockWeatherService? {
        let value = UserDefaults.standard.string(forKey: "demoWeather")
        return value == "real" ? nil : MockWeatherService(locationDenied: value == "denied")
    }

    func weather(place: String?) async -> Result<WeatherSource, WeatherFailure> {
        guard let place else {
            return locationDenied ? .failure(.locationDenied) : .success(Self.source(place: nil, warmer: 0, now: now()))
        }
        guard let index = Self.places.firstIndex(where: place.contains) else { return .failure(.placeNotFound) }
        let timeZone = Self.places[index] == "도쿄" ? TimeZone(identifier: "Asia/Tokyo") : nil
        return .success(Self.source(place: Self.places[index], warmer: [0, 2, 3, 1, 0, 1, 0, -1, 2][index], now: now(), timeZone: timeZone))
    }

    /// 오늘부터 열흘치 (그곳의 달력으로). 하늘·기온·비 확률·바람·자외선
    private static let pattern: [(String, String, Int, Int, Double, Double, Int)] = [
        ("구름 조금", "cloud.sun.fill", 17, 8, 0.1, 2.4, 4),
        ("비", "cloud.rain.fill", 16, 11, 0.7, 5.1, 2),
        ("흐림", "cloud.fill", 15, 9, 0.3, 3.2, 2),
        ("맑음", "sun.max.fill", 16, 6, 0, 2.0, 5),
        ("맑음", "sun.max.fill", 17, 7, 0, 1.8, 5),
        ("구름 많음", "cloud.fill", 14, 8, 0.2, 2.9, 3),
        ("비", "cloud.rain.fill", 12, 7, 0.6, 4.4, 1),
        ("구름 조금", "cloud.sun.fill", 13, 5, 0.1, 3.0, 4),
        ("맑음", "sun.max.fill", 12, 3, 0, 2.2, 4),
        ("눈", "cloud.snow.fill", 5, -1, 0.5, 3.6, 1),
    ]

    static func source(place: String?, warmer: Int, now: Date, timeZone: TimeZone? = nil) -> WeatherSource {
        let timeZone = timeZone ?? TimeZone(identifier: "Asia/Seoul") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        return WeatherSource(
            place: place, timeZone: timeZone,
            now: WeatherSource.Now(temperature: 14 + warmer, feelsLike: 12 + warmer, condition: "구름 조금", symbol: "cloud.sun.fill"),
            days: pattern.enumerated().compactMap { offset, day in
                calendar.date(byAdding: .day, value: offset, to: noon).map {
                    WeatherSource.Day(
                        date: $0, condition: day.0, symbol: day.1, high: day.2 + warmer, low: day.3 + warmer,
                        rainChance: day.4, wind: day.5, uvIndex: day.6
                    )
                }
            },
            // 지금부터 여섯 시간 (지어낸 값). 지금 위치면 지어낸 동네 이름을 붙인다
            hours: (0..<6).compactMap { offset in
                calendar.date(byAdding: .hour, value: offset, to: now).map {
                    WeatherSource.Hour(date: $0, symbol: offset < 2 ? "cloud.sun.fill" : "cloud.fill", temperature: 14 + warmer - (offset + 1) / 2)
                }
            },
            locality: place == nil ? "한빛시" : nil
        )
    }
}
#endif
