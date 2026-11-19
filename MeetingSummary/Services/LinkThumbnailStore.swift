import Foundation
import ImageIO
import Observation
import UIKit

/// 찾은 페이지 카드의 대표 그림을 받아 잠깐 들고 있는 곳 (D64).
///
/// 그림 주소는 그 페이지가 적어 둔 것(og:image)이고, 받는 것은 이 아이폰이 그 사이트의 그림 서버에 직접 접속하는 일이다. 그래서
/// - 카드가 화면에 그려질 때만 받는다 (미리 받지 않는다)
/// - 쿠키·캐시·저장된 로그인 없이 받는다 (`LinkThumbnailLoader`)
/// - 그림은 메모리에만 둔다 (대화 기록·파일·기기 캐시에 남기지 않는다). 앱이 뒤로 가면 버린다
/// - 받지 못한 주소는 버릴 때까지 다시 묻지 않는다 (같은 서버를 되풀이해 두드리지 않는다)
@MainActor
@Observable
final class LinkThumbnailStore {
    typealias Loader = @Sendable (URL) async -> Data?

    /// 한 번에 들고 있는 그림 수 (넘으면 오래된 것부터 버린다)
    nonisolated static let limit = 24
    /// 들고 있는 그림의 긴 변 (카드의 그림 자리는 56pt다)
    nonisolated static let maxPixel = 360

    private let load: Loader
    /// 모두 버린 횟수. 화면은 이 값이 바뀌면 들고 있던 그림을 버리고 다시 받는다
    private(set) var generation = 0
    @ObservationIgnored private var images: [URL: UIImage] = [:]
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var failed: Set<URL> = []

    init(load: @escaping Loader = LinkThumbnailLoader.fetch) {
        self.load = load
    }

    /// 그림을 받는다. 이미 들고 있으면 그것을 준다. 받지 못했거나 그림이 아니면 nil (그림 없이 그리면 된다)
    func image(for url: URL) async -> UIImage? {
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        let before = generation
        let data = await load(url)
        // 받는 사이에 화면이 사라졌거나 모두 버렸으면, 결과를 두지 않는다 (못 받았다고 적지도 않는다)
        guard !Task.isCancelled, before == generation else { return nil }
        guard let data, let image = Self.thumbnail(from: data) else {
            failed.insert(url)
            return nil
        }
        images[url] = image
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > Self.limit {
            images[order.removeFirst()] = nil
        }
        return image
    }

    /// 모두 버린다 (앱이 뒤로 갈 때, 다른 대화로 갈 때)
    func clear() {
        images = [:]
        order = []
        failed = []
        generation += 1
    }

    /// 지금 들고 있는 그림 수 (테스트 확인용)
    var heldCount: Int { images.count }

    /// 받은 것을 작은 그림으로 줄인다. 그림이 아니면 nil. 큰 그림도 통째로 풀지 않는다
    nonisolated static func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// 대표 그림을 받는 연결. 대화·맥·중계 서버와 아무것도 나누지 않는 따로 만든 연결이다
enum LinkThumbnailLoader {
    /// 받는 그림의 크기 한도
    static let maxBytes = 3_000_000

    /// 다른 곳으로 넘기는 응답은 공개 https 주소일 때만 따라간다 (내부 주소로 돌려보내는 것을 따라가지 않는다)
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            LinkThumbnailLoader.follows(request.url) ? request : nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    static func follows(_ url: URL?) -> Bool {
        AgentLink.publicURL(url?.absoluteString) != nil
    }

    /// 받아도 되는 응답인지: 성공, 그림, 한도 안
    static func accepts(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true else { return false }
        return http.expectedContentLength <= Int64(maxBytes)
    }

    static let fetch: LinkThumbnailStore.Loader = { url in
        guard follows(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard accepts(response) else { return nil }
            var data = Data()
            // 길이를 알리지 않는 응답도 한도에서 끊는다
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }
}
