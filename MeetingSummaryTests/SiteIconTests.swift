import Foundation
import Testing
import UIKit
@testable import MeetingSummary

// 연동 센터의 사이트 아이콘 (D131). 주소와 첫 화면은 지어낸 것이다.

@Suite("사이트 아이콘: 주소와 아이콘 고르기")
struct SiteIconTests {
    @Test func theHostComesFromTheNameOrTheKey() {
        #expect(SiteHost.of(site: "shop_test", name: "Shop.Example.test") == "shop.example.test")
        #expect(SiteHost.of(site: "naver", name: "네이버") == "www.naver.com")
        #expect(SiteHost.of(site: "mystery", name: "알 수 없는 곳") == nil)
        // 주소에 쓸 수 없는 꼴은 받지 않는다
        #expect(!SiteHost.isDomain("a b.test") && !SiteHost.isDomain("x.test/../y") && !SiteHost.isDomain("nodot"))
    }

    @Test func bigIconsComeFirstAndSVGIsSkipped() throws {
        let base = try #require(URL(string: "https://shop.example.test/home"))
        let html = """
        <html><head>
        <link rel="icon" href="/img/favicon-16.png" sizes="16x16">
        <link rel='icon' type='image/svg+xml' href='/img/logo.svg'>
        <LINK REL="icon" HREF="https://cdn.example.test/fav-48.png" sizes="48x48">
        <link rel="apple-touch-icon" href="touch.png">
        <link rel="stylesheet" href="/a.css">
        <link rel="icon" href="http://shop.example.test/insecure.png">
        </head></html>
        """
        let urls = SiteHost.iconCandidates(html: html, base: base).map(\.absoluteString)
        #expect(urls == [
            "https://shop.example.test/touch.png",
            "https://cdn.example.test/fav-48.png",
            "https://shop.example.test/img/favicon-16.png",
            "https://shop.example.test/favicon.ico",
        ])
    }

    @Test func aPageWithoutIconsFallsBackToFavicon() throws {
        let base = try #require(URL(string: "https://plain.example.test/"))
        #expect(SiteHost.iconCandidates(html: "<html></html>", base: base).map(\.absoluteString) == ["https://plain.example.test/favicon.ico"])
    }

    @Test func theLetterUsedWhenThereIsNoIcon() {
        #expect(SiteHost.initial("www.example.test") == "E")
        #expect(SiteHost.initial("네이버") == "네")
        #expect(SiteHost.initial("  ") == "?")
    }
}

@MainActor
@Suite("사이트 아이콘: 맥이 준 것 (D132)")
struct SiteIconMacTests {
    @Test func theMacTellsTheHost() throws {
        let sites = try AgentHTTPClient.decodeSites(data: Data("""
        {"sites":[{"site":"naver","name":"네이버","status":"logged_in","host":"Mail.Example.TEST"},
                  {"site":"odd","name":"이상한","status":"logged_in","host":"a b/c"},
                  {"site":"old","name":"예전","status":"logged_in"}]}
        """.utf8), status: 200)
        #expect(sites.map(\.host) == ["mail.example.test", nil, nil])
    }

    @Test func theMacIconComesFirstAndAMissingOneWaits() async throws {
        let store = SiteIconStore.shared
        let host = "icon-\(UUID().uuidString.prefix(8).lowercased()).example.test"
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
        // 맥에 아직 없다: 폰이 직접 받는 쪽으로 넘기고, 사흘 동안은 다시 묻지 않는다
        var asked = 0
        #expect(await store.loadFromMac(site: "s_\(host)", host: host) { asked += 1; return nil } == false)
        #expect(await store.loadFromMac(site: "s_\(host)", host: host) { asked += 1; return png } == false)
        #expect(asked == 1)
        // 다른 사이트에서 맥이 아이콘을 주면 그것을 쓴다
        let other = "other-" + host
        #expect(await store.loadFromMac(site: "s_\(other)", host: other) { png })
        #expect(store.image(for: other) != nil)
    }

    @Test func theFakeMacHandsOutIcons() async throws {
        let agent = MockAgentClient(v2: true)
        #expect(try await agent.siteIcon(site: "naver") == nil)
        await agent.setSiteIcon(Data([0x89, 0x50, 0x4E, 0x47]), for: "naver")
        #expect(try await agent.siteIcon(site: "naver")?.count == 4)
    }
}
