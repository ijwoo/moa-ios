import SwiftUI
import WebKit

// 쇼핑 "옆에서 봐 주기"의 화면들 (D74).
// 대화에는 카드 두 가지가 붙는다: 쇼핑 화면을 여는 카드(맥의 말 아래), 화면에서 읽은 것(내 말 아래).
// 쇼핑 화면은 대화 위에 가득 뜨는 웹 화면이고, 아래 막대의 "이 화면 확인해 줘"를 누를 때만 그 화면을 읽어 맥에 보낸다.
//
// "스스로 찾아 오기" (D75): 맥의 작업이 시키면 이 화면이 스스로 뜨고, 검색 결과와 상품 화면을 열어 읽는다.
// 그동안 아래 막대는 "에이전트가 찾고 있어요"와 [멈추기]로 바뀌고, 웹 화면은 손으로 움직일 수 없다 (멈추면 다시 내 것이 된다).

/// 대화 화면이 쇼핑 화면에 건네는 것
struct ShopDesk {
    let browser: ShopBrowser
    let session: AskSession
    /// 읽은 화면을 맥에 보낸다. 보내지 못했으면 false
    let check: @MainActor (ShopView) async -> Bool
}

extension EnvironmentValues {
    /// 쇼핑 화면 (D74). 대화 화면 안에서만 전해진다
    @Entry var shopDesk: ShopDesk?
}

extension View {
    /// 대화 화면이 그 안의 카드들에 건네는 것을 한 번에 단다: 상품 고르기(D72)와 쇼핑 화면(D74)
    func chatDesk(itemPicker: ItemPicker?, shop: ShopDesk) -> some View {
        modifier(ChatDesk(itemPicker: itemPicker, shop: shop))
    }

    /// 쇼핑 화면을 이 뷰 위에 가득 띄운다. 대화 화면의 내비게이션 바깥에 단다:
    /// 안쪽(대화 내용)에 달았더니 대화에 말이 붙을 때마다 쇼핑 화면이 새로 만들어져, 열려 있던 확인 결과가 사라졌다
    func shopCover(_ shop: ShopDesk) -> some View {
        modifier(ShopCover(shop: shop))
    }
}

private struct ChatDesk: ViewModifier {
    let itemPicker: ItemPicker?
    let shop: ShopDesk

    func body(content: Content) -> some View {
        content
            .environment(\.itemPicker, itemPicker)
            .environment(\.shopDesk, shop)
    }
}

private struct ShopCover: ViewModifier {
    let shop: ShopDesk

    func body(content: Content) -> some View {
        @Bindable var browser = shop.browser
        content
            .fullScreenCover(isPresented: $browser.isPresented) {
                ShopBrowserView(desk: shop)
            }
            // 맥의 작업이 시킨 일이 생기면 쇼핑 화면에서 한다 (D75). 일이 바뀌거나 사라지면 하던 것을 멈춘다
            .task(id: shop.session.browseJob?.id) {
                guard let job = shop.session.browseJob,
                      let result = await shop.browser.run(job.command, task: job.taskID) else { return }
                // 결과를 보내는 일은 이 `task`와 따로 둔다: 보내기 시작하면 "지금 할 일"이 바뀌어 이 `task`가 취소되기 때문이다
                Task { await shop.session.finishBrowse(job, result: result) }
            }
            .onChange(of: shop.session.browsingTaskID) { old, _ in
                // 쇼핑 화면을 쓰던 작업이 끝났거나 멈췄다: "찾는 중"을 걷는다.
                // 찾은 것을 가지고 끝났으면 대화로 돌아오고, 그 밖에는(막힘·실패·멈춤) 보던 화면을 그대로 둔다
                guard let old, shop.browser.drive?.taskID == old else { return }
                shop.browser.drive = nil
                // 로그인 화면에서 멈췄으면 그 화면을 그대로 둔다: 여기서 직접 로그인할 수 있게 (D79)
                if shop.session.phase(of: old) == .done, shop.browser.notice != .login { shop.browser.isPresented = false }
            }
    }
}

// MARK: - 대화에 붙는 카드

/// 맥이 "쇼핑 화면에서 같이 보자"고 한 말 아래에 붙는 카드. 누를 때만 쇼핑 화면이 열린다
struct ShopOpenCard: View {
    let query: String
    @Environment(\.shopDesk) private var desk

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("쇼핑 화면에서 같이 봐요", systemImage: "bag.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Chat.accent)
                .accessibilityAddTraits(.isHeader)

            Text("\(desk?.browser.site.name ?? "쇼핑 화면")에서 ‘\(query)’ 검색을 열어요. 둘러보다가 ‘이 화면 확인해 줘’를 누르면 그 화면의 가격·배송비·옵션을 읽어 같이 봐 드려요.")
                .lineSpacing(4)
                .foregroundStyle(DS.Chat.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                desk?.browser.open(query: query)
            } label: {
                Text("쇼핑 화면 열기").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Chat.userBubble)
            .controlSize(.large)
            .disabled(desk == nil)
            .accessibilityHint("앱 안에서 쇼핑 검색 화면을 엽니다")

            Text("앱은 화면을 읽기만 하고 아무것도 누르지 않아요. 로그인과 주문은 직접 해요.")
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .chatCard()
        #if DEBUG
        // 개발용: -demoShopOpen 이면 카드를 누른 것처럼 연다 (한 번만)
        .task {
            guard DemoData.arguments.contains("-demoShopOpen"), !DemoShop.didAutoOpen, let desk else { return }
            DemoShop.didAutoOpen = true
            desk.browser.open(query: query)
        }
        #endif
    }
}

/// "확인해 줘"로 보낸 내 말 아래에 붙는 카드: 그때 화면에서 읽어 맥에 보낸 것 그대로
struct ShopReadCard: View {
    let view: ShopView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("화면에서 읽은 것", systemImage: "text.viewfinder")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Chat.accent)
                Spacer(minLength: 4)
                Text(view.host)
                    .font(.caption)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ShopLines(view: view)
        }
        .chatCard(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// 읽은 값들 (이름표와 값). 읽지 못한 것도 적는다
struct ShopLines: View {
    let view: ShopView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(Array(view.lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Text(line.label)
                            .foregroundStyle(DS.Chat.textSecondary)
                            .gridColumnAlignment(.leading)
                        Text(line.value)
                            .foregroundStyle(DS.Chat.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.footnote)
            if !view.missing.isEmpty {
                Text("읽지 못한 것: \(view.missing.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(DS.Chat.warning)
            }
        }
    }
}

// MARK: - 쇼핑 화면

/// 웹 화면 (화면을 닫았다 열어도 같은 것을 다시 붙인다)
private struct ShopWebView: UIViewRepresentable {
    let browser: ShopBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// "확인해 줘"를 한 번 누른 결과
private struct ShopCheck: Identifiable {
    enum Outcome: Equatable {
        case read(ShopView)
        case nothing
        case moved
    }

    let id = UUID()
    let outcome: Outcome
    /// 누를 때까지 대화에 있던 말의 수 (그 뒤에 생긴 말이 이번 확인의 것이다)
    let baseline: Int
    /// 맥에 보내지 못했다
    var notSent = false
}

/// 대화 위에 가득 뜨는 쇼핑 화면: 위에는 지금 주소, 가운데는 웹 화면, 아래에는 이동 버튼과 "이 화면 확인해 줘"
struct ShopBrowserView: View {
    let desk: ShopDesk
    @Environment(\.openURL) private var openURL
    @State private var check: ShopCheck?
    @State private var isChecking = false
    @State private var confirmsClear = false
    @State private var showsGuide = false

    private var browser: ShopBrowser { desk.browser }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .top) {
                ShopWebView(browser: browser)
                    // 에이전트가 찾는 동안에는 손으로 움직이지 않는다 (둘이 같이 움직이면 엉뚱한 화면을 읽는다)
                    .allowsHitTesting(browser.drive == nil)
                if browser.isLoading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        .tint(DS.Chat.accent)
                        .accessibilityLabel("화면을 여는 중")
                }
            }
            if let notice = browser.notice {
                ShopNoticeBar(
                    notice: notice, siteName: browser.site.name,
                    onSafari: { openURL($0) }, onRetry: { browser.reload() }, onClose: { browser.notice = nil }
                )
            }
            if let drive = browser.drive {
                ShopDriveBar(text: drive.text) { stopDrive(drive.taskID) }
            } else {
                bottomBar
            }
        }
        .background(DS.Chat.background.ignoresSafeArea())
        .tint(DS.Chat.accent)
        .sheet(item: $check) { check in
            ShopCheckSheet(check: check, session: desk.session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsGuide) {
            ShopGuideSheet(siteName: browser.site.name, drives: desk.session.canDriveShop)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("쇼핑 화면의 로그인을 지울까요?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("로그인 지우기", role: .destructive) { Task { await browser.clearLogin() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 화면에 남은 로그인 상태와 쿠키를 모두 지워요. Safari나 맥의 로그인은 그대로예요.")
        }
        #if DEBUG
        .task { await runDemo() }
        #endif
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                browser.isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: DS.minTouch, height: DS.minTouch)
            }
            .accessibilityLabel("쇼핑 화면 닫기")
            // 에이전트가 찾는 동안에는 닫지 않는다 (아래의 "멈추기"로 멈춘다)
            .opacity(browser.drive == nil ? 1 : 0)
            .disabled(browser.drive != nil)

            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if browser.address != nil {
                        Image(systemName: "lock.fill").font(.caption2)
                    }
                    Text(ShopSite.host(of: browser.address) ?? browser.site.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(DS.Chat.textPrimary)
                Text(browser.query.map { "‘\($0)’ · \(browser.site.name)" } ?? browser.site.name)
                    .font(.caption)
                    .foregroundStyle(DS.Chat.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Menu {
                if browser.drive == nil {
                    Button("검색 결과로", systemImage: "magnifyingglass") { browser.home() }
                    if let url = browser.address, browser.site.allows(url), url.host()?.hasSuffix(".test") != true {
                        Button("Safari로 열기", systemImage: "safari") { openURL(url) }
                    }
                }
                Button("이 화면이 하는 일", systemImage: "info.circle") { showsGuide = true }
                if browser.drive == nil {
                    Divider()
                    Button("쇼핑 화면의 로그인 지우기", systemImage: "trash", role: .destructive) { confirmsClear = true }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: DS.minTouch, height: DS.minTouch)
            }
            .accessibilityLabel("더 보기")
        }
        .padding(.horizontal, 4)
        .background(DS.Chat.background)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Chat.hairline).frame(height: 1) }
    }

    /// 지금 "확인해 줘"를 누를 수 있는지와, 그 아래에 적을 한 줄
    private var checkState: (enabled: Bool, caption: String) {
        if browser.address == nil || (browser.isLoading && browser.page == nil) { return (false, "화면을 여는 중이에요") }
        if browser.page == nil { return (false, "검색 결과와 상품 화면에서만 읽어요. 이 화면은 읽지도 보내지도 않아요") }
        if isChecking || browser.isReading { return (false, "화면을 읽는 중이에요") }
        if !desk.session.canCheckShopNow { return (false, "대화에서 답을 기다리는 중이에요") }
        return (true, "누를 때만 이 화면의 상품 정보를 읽어 맥으로 보내요")
    }

    private var bottomBar: some View {
        let state = checkState
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                barButton("chevron.left", label: "뒤로", enabled: browser.canGoBack) { browser.goBack() }
                barButton("chevron.right", label: "앞으로", enabled: browser.canGoForward) { browser.goForward() }
                if browser.isLoading {
                    barButton("xmark", label: "멈추기", enabled: true) { browser.stop() }
                } else {
                    barButton("arrow.clockwise", label: "다시 열기", enabled: browser.address != nil) { browser.reload() }
                }
                Spacer(minLength: 8)
                Button {
                    Task { await runCheck() }
                } label: {
                    Label("이 화면 확인해 줘", systemImage: "text.viewfinder")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Chat.userBubble)
                .controlSize(.large)
                .disabled(!state.enabled)
            }
            Text(state.caption)
                .font(.caption)
                .foregroundStyle(DS.Chat.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(DS.Chat.background)
        .overlay(alignment: .top) { Rectangle().fill(DS.Chat.hairline).frame(height: 1) }
    }

    private func barButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: DS.minTouch, height: DS.minTouch)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// "멈추기": 화면을 멈추고, 그 작업도 멈춘다. 쇼핑 화면은 보던 그대로 남아 다시 내가 움직인다
    private func stopDrive(_ taskID: String) {
        browser.stopDrive()
        Task { await desk.session.cancelAgent(taskID) }
    }

    /// "확인해 줘": 지금 화면을 읽고, 읽은 것을 보여 주면서 맥에 보낸다
    private func runCheck() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let baseline = desk.session.messages.count
        switch await browser.read() {
        case .view(let view):
            let current = ShopCheck(outcome: .read(view), baseline: baseline)
            check = current
            let sent = await desk.check(view)
            if !sent, check?.id == current.id { check?.notSent = true }
        case .nothing:
            check = ShopCheck(outcome: .nothing, baseline: baseline)
        case .moved:
            check = ShopCheck(outcome: .moved, baseline: baseline)
        }
    }

    #if DEBUG
    /// 개발용: `-demoShopPage N`(가상 상품 N번째로), `-demoShopCart`(읽지 않는 화면), `-demoShopBlocked`(앱 안에서 열지 않는 주소),
    /// `-demoShopGuide`(안내), `-demoShopCheck`(확인해 줘를 누른다)
    private func runDemo() async {
        guard !DemoShop.didRunDemo else { return }
        DemoShop.didRunDemo = true
        func settle() async {
            for _ in 0..<50 where browser.isLoading || browser.address == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        await settle()
        if let number = DemoData.value(after: "-demoShopPage").flatMap(Int.init), DemoShop.products.indices.contains(number - 1) {
            browser.visit(DemoShop.productURL(DemoShop.products[number - 1]))
            await settle()
        }
        if DemoData.arguments.contains("-demoShopCart") {
            browser.visit(DemoShop.cartURL)
            await settle()
        }
        if DemoData.arguments.contains("-demoShopBlocked"), let url = URL(string: "https://pay.shop.test/order/1001") {
            browser.visit(url)
        }
        if DemoData.arguments.contains("-demoShopGuide") { showsGuide = true }
        if DemoData.arguments.contains("-demoShopCheck") { await runCheck() }
    }
    #endif
}

/// 에이전트가 찾는 동안의 아래 막대 (D75): 지금 하는 일과 "멈추기"
private struct ShopDriveBar: View {
    let text: String
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("에이전트가 찾고 있어요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Chat.textPrimary)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button("멈추기", action: onStop)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityHint("찾는 것을 멈춥니다. 쇼핑 화면은 그대로 남습니다")
            }
            Text("검색하고 상품 화면을 여는 것까지만 해요. 옵션·담기·주문은 누르지 않아요.")
                .font(.caption)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(DS.Chat.background)
        .overlay(alignment: .top) { Rectangle().fill(DS.Chat.hairline).frame(height: 1) }
        .animation(.default, value: text)
    }
}

/// 웹 화면 아래에 뜨는 알림: 열지 않은 주소, 접속 제한, 열지 못함
private struct ShopNoticeBar: View {
    let notice: ShopBrowser.Notice
    let siteName: String
    let onSafari: (URL) -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Chat.warning)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(DS.Chat.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if case .blocked(_, let url?) = notice, url.host()?.hasSuffix(".test") != true {
                    Button("Safari로 열기") { onSafari(url) }
                }
                if case .failed = notice {
                    Button("다시 시도", action: onRetry)
                }
                Button("닫기", action: onClose)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Chat.card)
        .overlay(alignment: .top) { Rectangle().fill(DS.Chat.hairline).frame(height: 1) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var icon: String {
        switch notice {
        case .blocked: "hand.raised.fill"
        case .limited: "exclamationmark.octagon.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .login: "person.badge.key.fill"
        }
    }

    private var title: String {
        switch notice {
        case .blocked(let host?, _): "\(host) 주소는 앱 안에서 열지 않아요"
        case .blocked: "다른 앱을 여는 링크는 열지 않아요"
        case .limited(let status): "접속이 제한됐어요 (응답 \(status))"
        case .failed: "화면을 열지 못했어요"
        case .login: "로그인 화면으로 넘어가서 멈췄어요"
        }
    }

    private var detail: String {
        switch notice {
        case .blocked(.some, _):
            "앱 안에서는 쇼핑 검색, 스토어의 상품, 로그인 주소만 열어요. 주문서·결제 같은 그 밖의 주소는 Safari에서 열 수 있어요."
        case .blocked:
            "쇼핑 화면은 앱 안에서만 봐요."
        case .limited:
            "\(siteName) 쪽에서 지금 이 네트워크의 접속을 제한했어요. 앱은 막힌 것을 돌아가거나 되풀이해 시도하지 않아요. 나중에 다시 열거나 Safari에서 봐 주세요."
        case .failed(let reason):
            reason
        case .login:
            "\(siteName)에서 찾던 화면 대신 로그인 화면이 나왔어요. 앱은 여기서 멈췄고 로그인을 대신 하지 않아요. 이 화면에서 직접 로그인한 뒤 다시 시켜 주세요. 아이디와 비밀번호는 앱이 읽지 않아요."
        }
    }
}

/// "확인해 줘"의 결과: 화면에서 읽은 것(맥에 보낸 것 그대로)과 그에 대한 답
private struct ShopCheckSheet: View {
    let check: ShopCheck
    let session: AskSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch check.outcome {
                    case .read(let view):
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("화면에서 읽은 것").font(.subheadline.weight(.semibold))
                                Spacer(minLength: 4)
                                Text(view.host).font(.caption).foregroundStyle(DS.Chat.textSecondary).lineLimit(1)
                            }
                            ShopLines(view: view)
                        }
                        .chatCard(padding: 14)
                        answer(to: view)
                        Text("읽은 것만 맥으로 보냈어요. 이 확인은 대화에도 남아요.")
                            .font(.footnote)
                            .foregroundStyle(DS.Chat.textSecondary)
                    case .nothing:
                        note("이 화면에서는 상품 정보를 읽지 못했어요", "아무것도 보내지 않았어요. 화면이 다 열린 뒤에 다시 눌러 보세요.")
                    case .moved:
                        note("읽는 사이에 화면이 바뀌었어요", "아무것도 보내지 않았어요. 다시 눌러 주세요.")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Chat.background)
            .navigationTitle("화면 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .tint(DS.Chat.accent)
    }

    @ViewBuilder
    private func answer(to view: ShopView) -> some View {
        let mine = session.shopCheck(of: view, after: check.baseline)
        let answers = mine.map { session.answers(after: $0.id) } ?? []
        if check.notSent {
            note("맥에 보내지 못했어요", "맥이 화면 확인을 받을 수 없는 상태예요. 대화 화면에서 연결을 확인해 주세요.")
        } else if answers.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("맥에 물어보는 중이에요").font(.subheadline).foregroundStyle(DS.Chat.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ForEach(answers) { message in
                switch message.role {
                case .assistant:
                    ChatText(text: message.text)
                        .lineSpacing(5)
                        .foregroundStyle(DS.Chat.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .chatBubble(DS.Chat.bubble)
                case .error:
                    note(message.text, "대화 화면에서 다시 시도할 수 있어요.")
                default:
                    Text("대화 화면에서 이어서 볼 수 있어요.")
                        .font(.footnote)
                        .foregroundStyle(DS.Chat.textSecondary)
                }
            }
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Chat.warning)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(DS.Chat.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 이 화면이 하는 일과 하지 않는 일
private struct ShopGuideSheet: View {
    let siteName: String
    /// 맥이 "스스로 찾아 오기"를 할 수 있다 (D75)
    var drives = false
    @Environment(\.dismiss) private var dismiss

    private var rows: [(icon: String, text: String)] {
        let found: [(icon: String, text: String)] = drives ? [
            ("sparkle.magnifyingglass", "살 것을 말하면 앱이 내가 보는 앞에서 검색 결과를 열고, 상품 화면을 몇 개 열어(한 번에 셋, 한 번 찾을 때 여섯까지) 읽어서 맥으로 보내요. 주소를 여는 것까지만 해요. ‘멈추기’를 누르면 바로 멈춰요."),
        ] : []
        return [
            ("iphone", "이 화면은 이 아이폰이 \(siteName)에 직접 접속해서 열어요. 맥은 쇼핑 사이트에 접속하지 않아요."),
            ("eye", "앱은 화면의 단추를 누르지 않아요. 옵션·담기·구매·동의는 직접 눌러요. 입력칸에 쓴 것(아이디·비밀번호)은 읽지 않아요."),
        ] + found + [
            ("text.viewfinder", (drives ? "그 밖에는 " : "") + "‘이 화면 확인해 줘’를 누를 때만, 검색 결과와 상품 화면의 상품 이름·가격·배송·옵션을 읽어 맥으로 보내요. 읽은 것은 그대로 보여 드려요."),
            ("eye.slash", "로그인·장바구니·주문·내 정보 화면은 읽지도 보내지도 않아요."),
            ("person.badge.key", "로그인은 직접 해요. 로그인 상태는 이 아이폰의 이 화면에만 남고, 메뉴의 ‘로그인 지우기’로 지울 수 있어요."),
            ("link", "쇼핑 검색, 스토어의 상품, 로그인 주소만 앱 안에서 열어요. 주문서·결제 같은 그 밖의 주소는 열지 않고 알려 드려요."),
            ("hand.raised", "사이트가 접속을 막으면 앱은 돌아가는 길을 찾지 않고 멈춰요."),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rows, id: \.text) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: row.icon)
                                .foregroundStyle(DS.Chat.accent)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(row.text)
                                .font(.subheadline)
                                .foregroundStyle(DS.Chat.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Chat.background)
            .navigationTitle("이 화면이 하는 일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .tint(DS.Chat.accent)
    }
}
