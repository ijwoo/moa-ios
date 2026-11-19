import CoreLocation
import Foundation
import MapKit
import WeatherKit

/// 실제 날씨: Apple 날씨(WeatherKit)에서 받는다 (D66).
///
/// 밖으로 나가는 것은 Apple로 가는 것뿐이다.
/// - 날씨를 볼 좌표: 말한 지역의 좌표, 또는 지금 위치(소수 둘째 자리로 줄인 값. 약 1km)
/// - 지역을 말했을 때 그 이름 (Apple 지도에서 좌표를 찾는다)
/// - 지금 위치의 날씨를 볼 때, 같은 줄인 좌표로 동네 이름을 묻는다 (Apple 지도. D104 — 날씨 카드에 "안양시"처럼 보이려고. 화면에만 쓴다)
/// 이 기기의 위치는 맥으로도 Claude로도 보내지 않고, 대화 기록에도 남기지 않는다
@MainActor
final class AppleWeatherService: WeatherProviding {
    /// 지금 위치를 처음 물을 때 만든다 (지역을 말한 물음에는 위치를 쓰지 않는다)
    private lazy var locator = DeviceLocator()

    func weather(place: String?) async -> Result<WeatherSource, WeatherFailure> {
        let location: CLLocation
        var name: String?
        var timeZone = TimeZone.current
        var locality: String?
        if let place {
            guard let found = await Self.find(place) else { return .failure(.placeNotFound) }
            location = found.location
            name = found.name
            timeZone = found.timeZone ?? .current
        } else {
            switch await locator.current() {
            case .success(let fix): location = Self.coarse(fix)
            case .failure(let failure): return .failure(failure)
            }
            locality = await Self.locality(of: location)
        }
        do {
            let (current, daily, hourly) = try await WeatherService.shared.weather(for: location, including: .current, .daily, .hourly)
            let from = Date.now.addingTimeInterval(-30 * 60)
            return .success(WeatherSource(
                place: name, timeZone: timeZone,
                now: WeatherSource.Now(
                    temperature: Self.celsius(current.temperature), feelsLike: Self.celsius(current.apparentTemperature),
                    condition: Self.text(for: current.condition), symbol: current.symbolName
                ),
                days: daily.forecast.map { day in
                    WeatherSource.Day(
                        date: day.date, condition: Self.text(for: day.condition), symbol: day.symbolName,
                        high: Self.celsius(day.highTemperature), low: Self.celsius(day.lowTemperature),
                        rainChance: day.precipitationChance,
                        wind: day.wind.speed.converted(to: .metersPerSecond).value, uvIndex: day.uvIndex.value
                    )
                },
                hours: hourly.forecast.filter { $0.date >= from }.prefix(Self.hourCount).map { hour in
                    WeatherSource.Hour(date: hour.date, symbol: hour.symbolName, temperature: Self.celsius(hour.temperature))
                },
                locality: locality
            ))
        } catch {
            return .failure(.unavailable)
        }
    }

    /// 지역 이름으로 좌표를 찾는다 (Apple 지도). 이름만 보낸다
    private static func find(_ place: String) async -> (location: CLLocation, name: String?, timeZone: TimeZone?)? {
        guard let request = MKGeocodingRequest(addressString: place) else { return nil }
        request.preferredLocale = Locale(identifier: "ko_KR")
        guard let item = try? await request.mapItems.first else { return nil }
        return (item.location, item.name, item.timeZone)
    }

    /// 시간별 줄에 쓰는 시간의 수
    nonisolated static let hourCount = 6

    /// 줄인 좌표의 동네 이름 (Apple 지도). 찾지 못하면 nil — 날씨는 그대로 보인다
    private static func locality(of location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "ko_KR")
        guard let item = try? await request.mapItems.first else { return nil }
        return item.addressRepresentations?.cityName
    }

    /// 지금 위치는 소수 둘째 자리까지만 쓴다 (약 1km. 날씨에는 그만큼이면 된다)
    nonisolated static func coarse(_ location: CLLocation) -> CLLocation {
        CLLocation(latitude: coarse(location.coordinate.latitude), longitude: coarse(location.coordinate.longitude))
    }

    nonisolated static func coarse(_ degrees: CLLocationDegrees) -> CLLocationDegrees {
        (degrees * 100).rounded() / 100
    }

    private nonisolated static func celsius(_ temperature: Measurement<UnitTemperature>) -> Int {
        Int(temperature.converted(to: .celsius).value.rounded())
    }

    /// 하늘 상태를 우리말로 (기기 언어와 상관없이 같은 말로 보여 주고, 같은 말을 맥에 알린다)
    nonisolated static func text(for condition: WeatherCondition) -> String {
        switch condition {
        case .clear: "맑음"
        case .mostlyClear: "대체로 맑음"
        case .partlyCloudy: "구름 조금"
        case .mostlyCloudy: "구름 많음"
        case .cloudy: "흐림"
        case .foggy: "안개"
        case .haze: "연무"
        case .smoky: "연기"
        case .breezy: "산들바람"
        case .windy: "바람 강함"
        case .drizzle: "이슬비"
        case .rain: "비"
        case .heavyRain: "강한 비"
        case .sunShowers: "여우비"
        case .isolatedThunderstorms: "곳에 따라 뇌우"
        case .scatteredThunderstorms: "산발적 뇌우"
        case .thunderstorms: "뇌우"
        case .strongStorms: "강한 폭풍우"
        case .flurries: "눈 날림"
        case .sunFlurries: "맑은 가운데 눈 날림"
        case .snow: "눈"
        case .heavySnow: "많은 눈"
        case .blowingSnow: "날리는 눈"
        case .blizzard: "눈보라"
        case .sleet: "진눈깨비"
        case .wintryMix: "눈과 비"
        case .freezingDrizzle: "어는 이슬비"
        case .freezingRain: "어는 비"
        case .hail: "우박"
        case .hot: "무더움"
        case .frigid: "매우 추움"
        case .blowingDust: "먼지 바람"
        case .tropicalStorm: "열대 폭풍"
        case .hurricane: "태풍"
        @unknown default: condition.description
        }
    }
}

/// 이 기기의 지금 위치를 한 번 받는다. 처음이면 권한을 묻는다 (앱을 쓰는 동안만)
@MainActor
final class DeviceLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        // 날씨에는 대략의 위치면 된다
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async -> Result<CLLocation, WeatherFailure> {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return .failure(.locationDenied)
        }
        let fix = await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            if fixWaiters.count == 1 { manager.requestLocation() }
        }
        return fix.map(Result.success) ?? .failure(.locationUnavailable)
    }

    private func finish(_ fix: CLLocation?) {
        let waiting = fixWaiters
        fixWaiters = []
        waiting.forEach { $0.resume(returning: fix) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiting = authorizationWaiters
            authorizationWaiters = []
            waiting.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last
        MainActor.assumeIsolated { finish(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
