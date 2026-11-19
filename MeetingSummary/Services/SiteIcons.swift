import Foundation
import SwiftUI
import UIKit

/// 연동 센터의 사이트 아이콘 (D131): 사이트가 스스로 내놓은 아이콘(파비콘)을 폰이 그 사이트에서 직접 받아 둔다.
/// 새 사이트가 생겨도 목록에 보일 때 저절로 받는다.
///
/// - 다른 아이콘 서비스(구글 등)를 거치지 않는다: 어떤 사이트에 로그인해 두었는지가 밖으로 나가지 않게
/// - 쿠키·로그인 없이 받는다 (그 사이트의 첫 화면과 아이콘 파일만)
/// - 받은 아이콘은 이 기기의 캐시 폴더에만 둔다 (백업되지 않는다). 못 받았으면 사흘 뒤에 다시 해 본다
/// - 못 받는 사이트(회사 안에서만 열리는 곳 등)는 이름의 첫 글자로 그린다
enum SiteHost {
    /// 이름만 있는 사이트 키 → 그 사이트의 주소 (맥이 도메인 이름을 주지 않는 것들)
    static let known: [String: String] = [
        "naver": "www.naver.com", "youtube": "www.youtube.com", "gmail": "mail.google.com",
        "google": "www.google.com", "coupang": "www.coupang.com", "kakao": "www.kakao.com", "daum": "www.daum.net",
    ]

    /// 사이트의 주소: 이름이나 키가 도메인 꼴이면 그것, 아니면 아는 주소. 모르면 nil
    static func of(site: String, name: String) -> String? {
        for candidate in [name, site] {
            let low = candidate.trimmingCharacters(in: .whitespaces).lowercased()
            if isDomain(low) { return low }
        }
        return known[site.lowercased()]
    }

    /// 아이콘이 없을 때 쓰는 이름의 첫 글자 (도메인이면 앞의 www.를 빼고, 영문은 대문자로)
    static func initial(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text.first.map { String($0).uppercased() } ?? "?"
    }

    /// 주소로 쓸 수 있는 꼴인지 (글자·숫자·붙임표와 점, 점이 하나 이상)
    static func isDomain(_ text: String) -> Bool {
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), text.count <= 253 else { return false }
        return text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." }
    }

    /// 첫 화면에서 아이콘 주소를 고른다: 큰 것(apple-touch-icon)을 먼저, 그다음 icon, 마지막으로 /favicon.ico. SVG는 그릴 수 없어 뺀다
    static func iconCandidates(html: String, base: URL) -> [URL] {
        var touch: [URL] = [], icons: [(URL, Int)] = []
        let tags = html.matches(of: #/<link\b[^>]*>/#.ignoresCase()).map { String(html[$0.range]) }
        for tag in tags {
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https", !url.path.lowercased().hasSuffix(".svg") else { continue }
            if attribute("type", in: tag)?.lowercased().contains("svg") == true { continue }
            if rel.contains("apple-touch-icon") {
                touch.append(url)
            } else {
                let size = attribute("sizes", in: tag).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
                icons.append((url, size))
            }
        }
        var result = touch + icons.sorted { $0.1 > $1.1 }.map(\.0)
        if let fallback = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL { result.append(fallback) }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 2...4 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }
}

@MainActor
@Observable
final class SiteIconStore {
    static let shared = SiteIconStore()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    /// 못 받은 주소를 다시 해 보기까지
    static let retryAfter: TimeInterval = 3 * 24 * 3600
    static let maxBytes = 1_000_000
    private static let failedKey = "siteIconFailures"

    private var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("SiteIcons", isDirectory: true)
    }

    /// 이 주소의 아이콘 (메모리 → 캐시 폴더). 없으면 nil
    func image(for host: String) -> UIImage? {
        if let image = images[host] { return image }
        guard let file = folder?.appendingPathComponent("\(host).png"), let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        images[host] = image
        return image
    }

    /// 맥이 받아 둔 아이콘을 먼저 묻는다 (D132). 맥에 없으면 false (사흘 뒤 다시 묻는다)
    func loadFromMac(site: String, host: String, fetch: () async -> Data?) async -> Bool {
        let key = "mac:\(site)"
        var failures = UserDefaults.standard.dictionary(forKey: Self.failedKey) as? [String: Double] ?? [:]
        if let failedAt = failures[key], Date.now.timeIntervalSince1970 - failedAt < Self.retryAfter { return false }
        guard !loading.contains(key) else { return false }
        loading.insert(key)
        defer { loading.remove(key) }
        guard let data = await fetch(), let image = UIImage(data: data), image.size.width >= 16 else {
            failures[key] = Date.now.timeIntervalSince1970
            UserDefaults.standard.set(failures, forKey: Self.failedKey)
            return false
        }
        save(Self.square(image), as: host)
        failures[key] = nil
        failures[host] = nil
        UserDefaults.standard.set(failures, forKey: Self.failedKey)
        return true
    }

    private func save(_ image: UIImage, as host: String) {
        images[host] = image
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: folder.appendingPathComponent("\(host).png"))
        }
    }

    /// 아직 없으면 받는다 (한 주소에 한 번씩. 못 받았으면 사흘 동안 다시 묻지 않는다)
    func load(_ host: String) async {
        #if DEBUG
        // 테스트에서는 밖으로 나가지 않는다
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #endif
        guard SiteHost.isDomain(host), image(for: host) == nil, !loading.contains(host) else { return }
        var failures = UserDefaults.standard.dictionary(forKey: Self.failedKey) as? [String: Double] ?? [:]
        if let failedAt = failures[host], Date.now.timeIntervalSince1970 - failedAt < Self.retryAfter { return }
        loading.insert(host)
        defer { loading.remove(host) }
        if let image = await fetch(host) {
            save(image, as: host)
            failures[host] = nil
        } else {
            failures[host] = Date.now.timeIntervalSince1970
        }
        UserDefaults.standard.set(failures, forKey: Self.failedKey)
    }

    private func fetch(_ host: String) async -> UIImage? {
        guard let home = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await session.data(from: home), let html = String(data: data.prefix(512_000), encoding: .utf8) {
            candidates = SiteHost.iconCandidates(html: html, base: response.url ?? home)
        }
        if candidates.isEmpty, let fallback = URL(string: "https://\(host)/favicon.ico") { candidates = [fallback] }
        for url in candidates.prefix(5) {
            guard let (data, _) = try? await session.data(from: url), data.count <= Self.maxBytes,
                  let image = UIImage(data: data), image.size.width >= 16 else { continue }
            return Self.square(image)
        }
        return nil
    }

    /// 64pt 정사각형으로 줄여 둔다 (큰 그림을 그대로 들고 있지 않게)
    private static func square(_ image: UIImage) -> UIImage {
        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let ratio = min(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

/// 사이트 아이콘 한 칸: 받은 아이콘은 흰 바탕의 둥근 칸에, 없으면 이름의 첫 글자
struct SiteIconView: View {
    let site: String
    let name: String
    /// 맥이 알려 준 호스트 (D132). 없으면 이름·키에서 찾는다
    var macHost: String? = nil
    /// 맥이 받아 둔 아이콘을 묻는다 (D132). nil이면 묻지 않는다
    var macIcon: (() async -> Data?)? = nil
    var size: CGFloat = 30
    @State private var store = SiteIconStore.shared

    private var host: String? { macHost ?? SiteHost.of(site: site, name: name) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let host, let image = store.image(for: host) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.14)
                    .frame(width: size, height: size)
                    // 어두운 화면에서도 로고가 보이게 흰 바탕
                    .background(Color.white, in: shape)
                    .overlay(shape.strokeBorder(Color.black.opacity(0.08)))
            } else {
                Text(SiteHost.initial(name))
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: size, height: size)
                    .background(DS.Colors.secondarySurface, in: shape)
            }
        }
        .accessibilityHidden(true)
        .task(id: host) {
            guard let host, store.image(for: host) == nil else { return }
            // 맥이 본 아이콘을 먼저 (회사 안에서만 열리는 사이트도 된다), 없으면 폰이 그 사이트에서 직접
            if let macIcon, await store.loadFromMac(site: site, host: host, fetch: macIcon) { return }
            await store.load(host)
        }
    }

}
