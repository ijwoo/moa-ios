import Foundation
import Observation
import UIKit
import WebKit

/// 앱 안의 쇼핑 화면 (D74). 이 아이폰이 쇼핑 사이트에 직접 접속해서 여는 웹 화면 하나를 들고 있다.
///
/// 지키는 것:
/// - 정해 둔 호스트만 연다 (`ShopSite.allows`). 주소는 앱이 만들거나(검색) 내가 화면에서 누른 것이다. 그 밖의 주소는 열지 않고 알려 준다
/// - 화면을 고치거나 누르는 스크립트를 넣지 않는다. 읽는 스크립트(`ShopReader`)는 내가 "확인해 줘"를 누를 때와,
///   내가 맡긴 찾기를 맥의 작업이 하는 동안(D75, `ShopDrive.swift`)에만, 검색 결과·상품 화면에서만 돈다
/// - 맥의 작업이 시킬 수 있는 것은 "검색해라"와 "목록의 몇 번째 상품을 열어라"뿐이다. 주소는 그때도 앱이 만들거나 앱이 읽은 목록에서 고른다.
///   단추(옵션·담기·구매·동의)는 누르지 않는다
/// - 브라우저를 꾸미지 않는다 (이 웹 화면이 원래 알리는 그대로 접속한다). 사이트가 접속을 막으면 다시 시도하거나 돌아가지 않고 알린다
/// - 로그인은 내가 이 화면에 직접 한다. 앱은 아이디·비밀번호를 읽지 않는다. 로그인 상태(쿠키)는 이 화면만 쓰는 저장소에 남고, `clearLogin`으로 지운다
@MainActor
@Observable
final class ShopBrowser: NSObject {
    /// 화면 위에 띄우는 알림
    enum Notice: Equatable {
        /// 앱 안에서 열지 않는 주소 (`host`가 없으면 다른 앱을 여는 링크). `url`은 Safari로 열 수 있을 때만
        case blocked(host: String?, url: URL?)
        /// 사이트가 접속을 제한했다 (응답 번호)
        case limited(status: Int)
        /// 열지 못했다
        case failed(String)
        /// 맡긴 찾기를 하다 로그인 화면으로 넘어가서 멈췄다 (D79). 로그인은 내가 이 화면에서 직접 한다
        case login
    }

    enum ReadResult: Equatable {
        case view(ShopView)
        /// 읽을 수 없는 화면이거나, 쓸 만한 것을 읽지 못했다
        case nothing
        /// 읽는 사이에 다른 화면으로 넘어갔다
        case moved
    }

    /// 이 화면만 쓰는 저장소의 이름 (로그인 상태가 여기에만 남는다. Safari나 맥의 브라우저와는 따로다)
    private static let storeID = UUID(uuidString: "6F1C2B7E-3A54-4E0B-9B5D-2C8E7A41D9F3")!

    let site: ShopSite
    /// 가상 쇼핑몰일 때만: 주소의 페이지를 앱이 그려서 준다 (어디에도 접속하지 않는다)
    @ObservationIgnored private let pages: (@MainActor (URL) -> String?)?
    @ObservationIgnored private let isPersistent: Bool

    /// 쇼핑 화면이 떠 있는지
    var isPresented = false
    /// 지금 보고 있는 검색어
    private(set) var query: String?
    private(set) var address: URL?
    /// 지금 화면이 읽을 수 있는 화면이면 그 종류와 주소
    private(set) var page: ShopPage?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isReading = false
    var notice: Notice?
    /// 맥의 작업이 이 화면을 옮기는 중이면 그 작업과 지금 하는 일 (D75). 그동안 화면은 내가 누를 수 없고, "멈추기"만 있다
    var drive: Drive?
    /// 맥의 작업이 시킨 일을 할 때의 빠르기 (화면을 여는 사이의 틈, 기다리는 한도)
    @ObservationIgnored var pace = Pace.app
    /// 시킨 일을 하며 기억해 두는 것 (읽은 목록의 링크, 연 횟수). 이 기기의 메모리에만 있다
    @ObservationIgnored var memory = DriveMemory()
    /// 방금 받은 화면의 응답 번호와, 지금까지 화면이 바뀐 횟수 (시킨 일을 할 때 화면이 다 왔는지 알아보는 데 쓴다)
    @ObservationIgnored var mainStatus: Int?
    /// 방금 화면을 열지 못했으면 그 까닭 (D77. 맥에 낱말로만 알린다). 새 화면을 열기 시작하면 지운다
    @ObservationIgnored var loadFailure: BrowseResult.Failure?
    @ObservationIgnored private(set) var commits = 0

    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// 가상 쇼핑몰: 앱이 방금 그려 넣은 주소 (이 주소의 이동은 내가 누른 것이 아니라 앱이 넣은 것이다)
    @ObservationIgnored private var expecting: URL?
    @ObservationIgnored private var demoStack: [URL] = []

    init(site: ShopSite = .naver, pages: (@MainActor (URL) -> String?)? = nil, isPersistent: Bool = true) {
        self.site = site
        self.pages = pages
        self.isPersistent = isPersistent && pages == nil
    }

    /// 앱이 쓰는 쇼핑 화면
    static func forApp() -> ShopBrowser {
        #if DEBUG
        // 가짜 맥과 함께일 때는 가상 쇼핑몰 (스크린샷과 확인용. 실제 사이트에 접속하지 않는다)
        if DemoData.isEnabled, DemoData.arguments.contains("-demoAgent") {
            // -demoShopLogin: 상품 화면이 로그인 화면으로 넘어간다 (로그인 화면에서 멈추는 것을 찍을 때)
            let toLogin = DemoData.arguments.contains("-demoShopLogin")
            let browser = ShopBrowser(site: .demo, pages: { url in
                if toLogin, ShopSite.demo.page(for: url)?.kind == .product {
                    return "<html><body><script>location.replace('https://login.shop.test/')</script></body></html>"
                }
                return DemoShop.html(for: url)
            }, isPersistent: false)
            // 가상 쇼핑몰은 어디에도 접속하지 않는다: 틈을 짧게 두되, 화면이 넘어가는 것은 보이게 한다
            browser.pace = Pace(
                settle: .milliseconds(400), gap: .milliseconds(900), loadLimit: .seconds(10), readGap: .milliseconds(200), waitsForActive: false
            )
            return browser
        }
        #endif
        return ShopBrowser()
    }

    // MARK: - 열기

    /// 검색어로 쇼핑 화면을 연다. 같은 검색어로 다시 열면 보던 화면 그대로다
    func open(query: String) {
        let wanted = ShopText.clean(query, limit: ShopView.queryLimit)
        if wanted != self.query || web?.url == nil {
            self.query = wanted
            home()
        }
        isPresented = true
    }

    /// 맥의 작업이 시킨 검색 (D75): 쇼핑 화면을 띄우고 검색 결과로 간다.
    /// 같은 검색어의 검색 결과를 이미 보고 있으면 다시 받지 않는다 (사이트에 같은 것을 두 번 묻지 않는다). 새로 받기 시작했으면 true
    func search(_ query: String) -> Bool {
        let wanted = ShopText.clean(query, limit: ShopView.queryLimit)
        isPresented = true
        let shown = address.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "query" }?.value
        if wanted == self.query, page?.kind == .list, shown == wanted, notice == nil, !isLoading { return false }
        self.query = wanted
        home()
        return true
    }

    /// 검색 결과로 간다
    func home() {
        guard let query, let url = site.searchURL(for: query) else {
            notice = .failed("검색어가 없어요.")
            return
        }
        demoStack = []
        visit(url)
    }

    /// 앱이 만든 주소로 간다 (검색 주소, 가상 쇼핑몰의 주소). 정해 둔 호스트가 아니면 열지 않고 알린다
    func visit(_ url: URL) {
        guard site.allows(url) else { return block(url, byUser: true) }
        let view = webView()
        notice = nil
        loadFailure = nil
        if let pages {
            guard let html = pages(url) else {
                notice = .failed("없는 화면이에요.")
                return
            }
            expecting = url
            if demoStack.last != url { demoStack.append(url) }
            view.loadHTMLString(html, baseURL: url)
        } else {
            view.load(URLRequest(url: url))
        }
        sync()
    }

    func goBack() {
        if pages != nil {
            guard demoStack.count > 1 else { return }
            demoStack.removeLast()
            if let url = demoStack.last { visit(url) }
        } else {
            web?.goBack()
        }
    }

    func goForward() { web?.goForward() }

    func reload() {
        notice = nil
        if pages != nil, let url = demoStack.last {
            visit(url)
        } else if web?.url != nil {
            web?.reload()
        } else {
            home()
        }
    }

    func stop() { web?.stopLoading() }

    /// 화면에 붙일 웹 화면 (처음 쓸 때 만든다)
    func webView() -> WKWebView {
        if let web { return web }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.store(isPersistent: isPersistent)
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = pages == nil
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        #if DEBUG
        view.isInspectable = true
        #endif
        // 페이지가 주소만 바꾸는 이동(화면을 새로 받지 않는 이동)도 따라간다
        observations = [
            view.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
        web = view
        return view
    }

    private static func store(isPersistent: Bool) -> WKWebsiteDataStore {
        isPersistent ? WKWebsiteDataStore(forIdentifier: storeID) : .nonPersistent()
    }

    private func sync() {
        guard let web else { return }
        let url = web.url.flatMap { $0.scheme == "about" ? nil : $0 }
        if address != url { address = url }
        let readable = site.page(for: url)
        if page != readable { page = readable }
        if isLoading != web.isLoading { isLoading = web.isLoading }
        if progress != web.estimatedProgress { progress = web.estimatedProgress }
        let back = pages == nil ? web.canGoBack : demoStack.count > 1
        if canGoBack != back { canGoBack = back }
        let forward = pages == nil && web.canGoForward
        if canGoForward != forward { canGoForward = forward }
    }

    private func block(_ url: URL?, byUser: Bool) {
        let scheme = url?.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            notice = .blocked(host: ShopSite.host(of: url), url: scheme == "https" ? url : nil)
        } else if byUser {
            // 다른 앱을 여는 링크 같은 것: 내가 눌렀을 때만 알린다 (페이지가 스스로 시도한 것은 조용히 열지 않는다)
            notice = .blocked(host: nil, url: nil)
        }
    }

    // MARK: - 읽기

    /// 지금 화면을 읽는다. 내가 "확인해 줘"를 눌렀을 때만 부른다.
    /// 검색 결과·상품 화면이 아니면 읽지 않는다. 읽는 사이에 화면이 바뀌었으면 읽은 것을 버린다
    func read() async -> ReadResult {
        await readWithLinks().result
    }

    /// 위와 같되, 목록이면 상품마다 그 상품으로 가는 링크의 주소도 함께 준다 (맥의 작업이 시킨 "열어라"에 쓴다, D75).
    /// 주소는 이 기기에만 둔다
    func readWithLinks() async -> (result: ReadResult, links: [[URL]], gaps: [String?]) {
        guard let web, !isReading, let page = site.page(for: web.url) else { return (.nothing, [], []) }
        isReading = true
        defer { isReading = false }
        let result = try? await web.callAsyncJavaScript(
            ShopReader.script, arguments: ["kind": page.kind.rawValue], in: nil, contentWorld: .world(name: ShopReader.worldName)
        )
        guard site.page(for: web.url) == page else { return (.moved, [], []) }
        guard let read = ShopView.parse(page: page, json: result as? String) else { return (.nothing, [], []) }
        return (.view(read.view), read.links, read.gaps)
    }

    // MARK: - 로그인 지우기

    /// 이 화면에 남은 것(로그인 상태, 쿠키, 저장된 페이지)을 모두 지우고 검색 결과로 돌아간다
    func clearLogin() async {
        let store = web?.configuration.websiteDataStore ?? Self.store(isPersistent: isPersistent)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        if query != nil { home() }
    }
}

// MARK: - 이동

extension ShopBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let byUser = navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted
        // 새 창으로 열려는 링크: 창을 새로 만들지 않고, 열 수 있는 주소면 이 화면에서 연다
        guard let frame = navigationAction.targetFrame else {
            if let url, site.allows(url) { visit(url) } else { block(url, byUser: true) }
            return .cancel
        }
        // 화면 안의 틀(iframe)은 그 페이지의 일부다
        guard frame.isMainFrame else {
            return ["https", "about", "data", "blob"].contains(url?.scheme?.lowercased() ?? "") ? .allow : .cancel
        }
        if url?.absoluteString == "about:blank" { return .allow }
        guard let url, site.allows(url) else {
            block(url, byUser: byUser)
            return .cancel
        }
        if pages != nil {
            if expecting == url {
                expecting = nil
                return .allow
            }
            // 가상 쇼핑몰: 누른 링크의 페이지도 앱이 그려서 보여 준다
            visit(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // 사이트가 접속을 제한했다: 사이트가 보낸 화면은 그대로 보여 주고, 앱은 다시 시도하거나 돌아가지 않는다
        if navigationResponse.isForMainFrame, let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode {
            mainStatus = status
            if status == 418 || status == 429 { notice = .limited(status: status) }
        }
        // 화면에 보여 줄 수 없는 것(파일)은 받지 않는다
        return navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if case .limited = notice { notice = nil }
        if case .failed = notice { notice = nil }
        sync()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if case .blocked = notice { notice = nil }
        // 로그인 화면을 벗어났으면 "로그인 화면에서 멈췄다"는 알림을 걷는다
        if case .login = notice, !site.isLogin(webView.url) { notice = nil }
        commits += 1
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        notice = .failed("화면이 멈췄어요. 다시 열어 주세요.")
        loadFailure = .webCrashed
        sync()
    }

    private func failed(_ error: any Error) {
        sync()
        let error = error as NSError
        // 내가 멈췄거나, 열지 않기로 한 주소라 멈춘 것은 실패가 아니다
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        notice = .failed(error.localizedDescription)
        loadFailure = Self.failure(for: error)
    }

    /// 열지 못한 까닭을 낱말로 (오류 문장과 주소는 이 기기 밖으로 나가지 않는다)
    static func failure(for error: NSError) -> BrowseResult.Failure {
        guard error.domain == NSURLErrorDomain else { return .loadError }
        switch error.code {
        case NSURLErrorNetworkConnectionLost: return .netLost
        case NSURLErrorTimedOut: return .netTimeout
        case NSURLErrorNotConnectedToInternet: return .netOffline
        default: return .loadError
        }
    }
}

// MARK: - 창과 알림창

extension ShopBrowser: WKUIDelegate {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // 새 창은 만들지 않는다. 열 수 있는 주소면 이 화면에서 연다
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" {
            if site.allows(url) { visit(url) } else { block(url, byUser: true) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(message, in: webView, confirms: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(message, in: webView, confirms: true)
    }

    /// 페이지가 띄운 알림창을 그대로 보여 준다 (답은 내가 누른다)
    private func ask(_ message: String, in webView: WKWebView, confirms: Bool) async -> Bool {
        var presenter = webView.window?.rootViewController
        while let next = presenter?.presentedViewController, !next.isBeingDismissed { presenter = next }
        guard let presenter else { return false }
        let host = ShopSite.host(of: webView.url) ?? site.name
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: host, message: String(message.prefix(600)), preferredStyle: .alert)
            if confirms {
                alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in continuation.resume(returning: false) })
            }
            alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }
}
