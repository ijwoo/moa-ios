import SwiftUI

/// 연동 센터 (내 정보 > 연결 및 계정, D49·D51): 지금 무엇이 연동되어 있는지 한곳에서 보고, 여기서 연결·확인·로그아웃한다.
///
/// 브라우저 로그인(맥의 에이전트 브라우저)과 메일 계정(맥의 키체인)을 묶음 둘로 나눠 보인다. 서로 다른 연결이고,
/// 둘 다 연결된 맥이 지원한다고 알릴 때만 묶음이 나온다.
/// 아이디·비밀번호·앱 비밀번호는 보여 주지 않는다. 보이는 것은 상태뿐이다.
/// 사용자가 이 아이폰의 키체인에 저장해 둔 사이트 로그인 값(D78)도 "있다"는 것만 보이고, 여기서 지울 수 있다.
/// 줄에는 상태를 두고, 주요 동작(로그인, 계정 연결)은 강조색 줄로, 보조 동작(다시 확인, 로그아웃)은 메뉴와 묶음 제목 옆에 둔다.
struct IntegrationsView: View {
    let mail: MailAccountsModel
    let sites: SiteAccountsModel

    @State private var connecting: MailConnectTarget?
    @State private var loggingIn: SiteLoginTarget?
    /// 로그아웃할지 물어볼 사이트
    @State private var loggingOut: SiteStatus?
    /// 처음 상태를 받는 중인지 (받기 전에 "연결되지 않았어요"가 먼저 보이지 않게)
    @State private var isLoading = true

    struct SiteLoginTarget: Identifiable {
        let id = UUID()
        let flow: SiteLoginFlow
    }

    struct MailConnectTarget: Identifiable {
        let id = UUID()
        var provider: MailProvider = .naver
        var address = ""
    }

    /// 이 화면의 강조색 (D142): 시스템 파랑 대신 모아의 포인트 색 (D144부터 고른 강조색)
    static var point: Color { DS.Chat.userBubble }

    var body: some View {
        List {
            if sites.isSupported { sitesSection }
            // 이 아이폰에 있는 것이라 맥에 연결되지 않아도 보이고 지울 수 있다 (하위 화면으로, D142)
            if !sites.savedSites.isEmpty { savedSection }
            if mail.isSupported { mailSection }
            if !sites.isSupported, !mail.isSupported { emptySection }
        }
        .settingsListStyle()
        .tint(Self.point)
        .navigationTitle("연동 센터")
        .navigationBarTitleDisplayMode(.inline)
        // 뒤로 가기가 있는 하위 화면: 떠 있는 탭바가 목록을 가리지 않게 숨긴다 (D142)
        .toolbar(.hidden, for: .tabBar)
        .task { await reload() }
        // 닫히면 다시 받는다: 메일 연결을 마쳤으면 새 계정이 메일 계정 묶음에 바로 보이게
        .sheet(item: $loggingIn, onDismiss: { Task { await reload() } }) { target in
            SiteLoginSheet(flow: target.flow)
        }
        .sheet(item: $connecting) { target in
            MailConnectSheet(provider: target.provider, address: target.address) { provider, address, password in
                try await mail.connect(provider: provider, address: address, password: password)
            }
        }
    }

    /// 들어올 때마다 맥에서 상태를 다시 받는다 (대화에서 방금 로그인했으면 여기서 바로 보이게)
    private func reload() async {
        await sites.load()
        await mail.load()
        isLoading = false
    }

    // MARK: - 연동된 것이 없을 때

    /// 맥에 연결되지 않았거나, 맥이 연동 기능을 알리지 않을 때
    private var emptySection: some View {
        Section {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(MailKeeper.name)에서 연동 상태를 받고 있어요…")
                        .font(DS.Settings.captionFont)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            } else {
                SettingsRow(
                    icon: .link, tint: DS.Colors.textSecondary, title: "연동 상태를 받지 못했어요",
                    subtitle: "\(MailKeeper.name)의 에이전트에 연결되면 브라우저 로그인과 메일 계정을 여기에서 볼 수 있어요."
                )
                .accessibilityElement(children: .combine)
                Button("다시 확인") {
                    isLoading = true
                    Task { await reload() }
                }
            }
        }
    }

    // MARK: - 브라우저 로그인 (D48)

    /// 맥의 에이전트 브라우저에 남아 있는 사이트 로그인. 메일 계정과는 다른 연결이다
    private var sitesSection: some View {
        Section {
            if sites.loginSites.isEmpty {
                SettingsRow(
                    icon: .globe, tint: DS.Colors.textSecondary,
                    title: sites.loadFailed ? "로그인 상태를 받지 못했어요" : "로그인할 수 있는 사이트가 아직 없어요"
                )
                .accessibilityElement(children: .combine)
            }
            // 메일 연결은 로그인이 아니라 여기에 두지 않는다 (메일 계정 묶음에 있다)
            ForEach(sites.loginSites) { site in
                siteRow(site)
            }
            if let problem = sites.problem {
                Text(problem)
                    .font(DS.Settings.captionFont)
                    .foregroundStyle(DS.Colors.warning)
            }
        } header: {
            Text("브라우저 로그인")
        } footer: {
            Text("맥의 에이전트 브라우저에 로그인 상태만 남아요. 아이디와 비밀번호는 맥에 저장하지 않아요. 이 아이폰에는 로그인할 때 저장을 켠 것만 키체인에 보관해요.")
        }
    }

    // MARK: - 이 아이폰에 저장한 로그인 (D78)

    /// 이 아이폰의 키체인에 저장해 둔 사이트 로그인 값. 위 목록과 같은 사이트가 되풀이되지 않게, 여기서는 한 줄로 두고
    /// 무엇이 있는지와 지우는 길은 하위 화면에 둔다 (D142). 위 사이트 줄에는 "키체인 저장"으로 보인다
    private var savedSection: some View {
        Section {
            NavigationLink {
                SavedLoginsView(sites: sites)
            } label: {
                SettingsRow(icon: .keyRound, tint: Self.point, title: "저장된 로그인") {
                    Text("\(sites.savedSites.count)").foregroundStyle(DS.Colors.textSecondary)
                }
            }
        } footer: {
            Text("로그인할 때 저장을 켠 아이디와 비밀번호예요. 이 아이폰의 키체인에만 있어요.")
        }
    }

    /// 앱에서 로그인할 수 있는 사이트의 로그인 방법
    private struct LoginAction {
        /// 저장해 둔 값으로 다시 로그인할 때의 확인 방법 이름 ("Face ID"). 없으면 직접 로그인
        let quick: String?
    }

    /// 로그인되어 있거나 앱에서 할 수 없으면 nil
    private func loginAction(_ site: SiteStatus) -> LoginAction? {
        guard site.status != .loggedIn, site.canLogInFromApp else { return nil }
        // 저장해 둔 값이 있는 아이디·비밀번호 사이트면 얼굴 확인 한 번으로 다시 로그인한다 (D122)
        return LoginAction(quick: site.reloginsWithPassword ? SiteLoginFlow.quickUnlock(for: site.site) : nil)
    }

    private func logIn(_ site: SiteStatus, quick: Bool) {
        guard let flow = sites.flow(for: site.site) else { return }
        flow.autoUsesSaved = quick
        loggingIn = SiteLoginTarget(flow: flow)
    }

    /// 줄의 한 줄 문구 (D143): 확인 중 / 로그인 상태(단추가 배지 자리를 쓸 때) · 언제 확인했는지 (짧게)
    private func siteSubtitle(_ site: SiteStatus, action: Bool) -> String? {
        if sites.checking == site.site { return "\(MailKeeper.name)에서 열어 보고 있어요…" }
        var parts: [String] = []
        // 로그인 단추가 오른쪽 배지 자리를 쓰면 상태는 여기에 적는다
        if action { parts.append(site.status.badge.text) }
        if let checked = Self.shortCheckedText(site) { parts.append(checked) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "오전 10:45 확인" · "11월 17일 확인" (오늘이 아니면 날짜만. 확인한 적이 없으면 nil)
    static func shortCheckedText(_ site: SiteStatus) -> String? {
        guard let date = site.checkedAt else { return nil }
        let when = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month().day())
        return "\(when) 확인"
    }

    private func siteRow(_ site: SiteStatus) -> some View {
        let isChecking = sites.checking == site.site
        let action = loginAction(site)
        let subtitle = siteSubtitle(site, action: action != nil)
        let saved = sites.savedSites.contains { $0.site == site.site }
        // 지구본 대신 그 사이트의 아이콘 (D131. 못 받으면 이름의 첫 글자).
        // 줄마다 짜임이 같게 (D143): 아이콘 · 이름과 한 줄 문구 · 오른쪽 끝에 고정된 배지나 단추. 글이 길어도 단추가 아래로 내려가지 않는다
        return HStack(spacing: 12) {
            SiteIconView(site: site.site, name: site.name, macHost: site.host, macIcon: { [sites] in await sites.macIcon(site.site) }, size: 28)
            VStack(alignment: .leading, spacing: DS.Settings.textSpacing) {
                HStack(spacing: 5) {
                    Text(site.name)
                        .font(DS.Settings.titleFont)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    // 이 아이폰 키체인에 저장한 값이 있다 (글 대신 작은 열쇠)
                    if saved {
                        Image(systemName: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .accessibilityLabel("키체인 저장")
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Settings.captionFont)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            HStack(spacing: 6) {
                if isChecking {
                    StatusBadge(text: site.status.badge.text, tone: site.status.badge.tone)
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Self.moreWidth)
                } else if let action {
                    // 주요 동작: 로그인되어 있지 않으면 배지 자리의 캡슐 단추로 바로 로그인한다 (D142)
                    LoginCapsule(title: action.quick == nil ? "로그인" : "재로그인") {
                        logIn(site, quick: action.quick != nil)
                    }
                    .disabled(sites.isBusy)
                    .accessibilityLabel(action.quick.map { "\(site.name), \($0)로 다시 로그인" } ?? "\(site.name) 로그인")
                } else {
                    StatusBadge(text: site.status.badge.text, tone: site.status.badge.tone)
                    if site.status == .loggedIn { siteMenu(site) }
                }
            }
            .fixedSize()
        }
        // 확인 창은 그 사이트 줄에서 뜬다
        .confirmationDialog(
            "\(site.name) 로그아웃",
            isPresented: Binding(get: { loggingOut?.site == site.site }, set: { if !$0 { loggingOut = nil } }),
            titleVisibility: .visible
        ) {
            Button("로그아웃", role: .destructive) { Task { await sites.logout(site.site) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("맥의 에이전트 브라우저에서 \(site.name) 로그인 상태를 지워요. 다시 쓰려면 다시 로그인해야 해요.")
        }
    }

    private static let moreWidth: CGFloat = 32
    /// 묶음 제목 옆 버튼이 제목 줄 밖으로 넘치는 만큼 (누르는 영역 44pt를 지키면서 줄 높이는 늘리지 않는다)
    private static let headerActionOverlap: CGFloat = 12

    /// 보조 동작(다시 확인, 로그아웃)은 줄 끝의 더 보기 메뉴에 둔다 (상태와 주요 동작보다 눈에 띄지 않게)
    private func siteMenu(_ site: SiteStatus) -> some View {
        Menu {
            Button {
                Task { await sites.check(site.site) }
            } label: {
                Text("다시 확인")
                Text("저장된 로그인이 살아 있는지 \(MailKeeper.name)이 열어 봐요. 20초쯤 걸릴 수 있어요")
            }
            Button("로그아웃", role: .destructive) { loggingOut = site }
                .disabled(sites.isBusy)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: Self.moreWidth, height: DS.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(site.name) 더 보기")
        .accessibilityHint("다시 확인하거나 로그아웃합니다")
    }

    /// "마지막 확인 오후 3:10" (확인한 적이 없으면 nil)
    static func checkedText(_ site: SiteStatus) -> String? {
        guard let date = site.checkedAt else { return nil }
        let day = Calendar.current.isDateInToday(date) ? "" : date.formatted(.dateTime.month().day()) + " "
        return "마지막 확인 \(day)\(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - 메일 계정

    /// 메일을 보낼 때 쓰는 내 주소와 로그인 상태. 비밀번호는 보여 주지 않는다 (앱으로 오지 않는다)
    private var mailSection: some View {
        // 맥이 대신 해 주는 메일 연결 ("네이버 메일 연결"). 주소도 그 안에서 받으므로, 있으면 "주소를 먼저 넣어야 해요"라고 하지 않는다
        let setups = sites.isSupported ? sites.mailSetups : []
        return Section {
            if mail.accounts.isEmpty {
                SettingsRow(
                    icon: .mail, tint: DS.Colors.textSecondary,
                    title: Self.emptyMailTitle(loadFailed: mail.loadFailed, canSetUp: !setups.isEmpty),
                    subtitle: mail.loadFailed || !setups.isEmpty ? nil : "\(MailKeeper.name)의 에이전트 설정에 내 주소를 먼저 넣어야 해요"
                )
                .accessibilityElement(children: .combine)
            }
            ForEach(mail.accounts) { account in
                if account.status.needsConnect, mail.canConnect {
                    // 다시 연결하면 풀리는 상태: 줄을 누르면 그 주소로 연결 화면이 열린다
                    Button {
                        connecting = MailConnectTarget(provider: MailProvider(rawValue: account.provider) ?? .naver, address: account.address)
                    } label: {
                        HStack(spacing: 6) {
                            mailRow(account)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel("\(account.providerName) 계정 연결, \(account.status.badge.text)")
                } else {
                    mailRow(account)
                        .accessibilityElement(children: .combine)
                }
            }
            ForEach(setups) { site in
                Button {
                    if let flow = sites.flow(for: site.site) { loggingIn = SiteLoginTarget(flow: flow) }
                } label: {
                    SettingsRow(
                        icon: .sparkles, tint: Self.point, title: site.name, titleColor: Self.point,
                        subtitle: "에이전트가 \(MailKeeper.name)의 브라우저에서 메일 설정을 대신 해요. 바꾸기 전에 물어봐요"
                    )
                }
                .disabled(sites.isBusy)
            }
            // 보낼 수 있는 주소가 하나도 없으면 앱 비밀번호를 직접 넣어 연결할 수 있는 것이 없다
            if mail.canConnect, !mail.accounts.isEmpty || mail.loadFailed {
                Button {
                    connecting = MailConnectTarget()
                } label: {
                    SettingsActionLabel(title: "계정 연결", icon: .plus, color: Self.point)
                }
                .disabled(mail.isChecking)
            }
        } header: {
            // 보조 동작(다시 확인)은 묶음 제목 옆에 작게 둔다
            HStack(spacing: 8) {
                Text("메일 계정")
                Spacer(minLength: 8)
                if mail.isChecking {
                    ProgressView().controlSize(.small)
                    Text("\(MailKeeper.name)에서 로그인해 보고 있어요…")
                } else {
                    // 글자는 작게 두고, 누르는 영역만 넓힌다 (묶음 제목 줄의 높이는 그대로)
                    Button {
                        Task { await mail.load(check: true) }
                    } label: {
                        Text("다시 확인")
                            .font(DS.Settings.captionFont)
                            .frame(minWidth: DS.minTouch, minHeight: DS.minTouch, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .padding(.vertical, -Self.headerActionOverlap)
                        .accessibilityLabel("메일 계정 다시 확인")
                        .accessibilityHint("계정마다 다시 로그인해 봅니다. 20초쯤 걸릴 수 있어요")
                }
            }
        } footer: {
            Text("메일은 보내기 전에 항상 승인을 받아요. 앱 비밀번호는 이 아이폰이 아니라 \(MailKeeper.store)에만 보관돼요.")
        }
    }

    static func emptyMailTitle(loadFailed: Bool, canSetUp: Bool) -> String {
        if loadFailed { return "계정 목록을 받지 못했어요" }
        return canSetUp ? "연결된 메일 계정이 아직 없어요" : "보낼 수 있는 내 주소가 아직 없어요"
    }

    private func mailRow(_ account: MailAccount) -> some View {
        SettingsRow(
            icon: .mail, tint: Self.point, title: account.isDefault ? "\(account.providerName) · 기본" : account.providerName,
            subtitle: account.address
        ) {
            StatusBadge(text: account.status.badge.text, tone: account.status.badge.tone)
        }
    }
}

/// 사이트 줄의 로그인 단추 (D142): 상태 배지 자리에 놓는 작은 캡슐. 모아의 민트에 흰 글자
private struct LoginCapsule: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Chat.onUserBubble)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(IntegrationsView.point.opacity(isEnabled ? 1 : 0.4), in: Capsule())
                // 보이는 캡슐은 작게, 누르는 영역은 44pt
                .frame(minHeight: DS.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// 이 아이폰에 저장한 로그인 (D78, D142): 값은 보여 주지 않고 무엇이 있는지와 지우는 길만 둔다.
/// 줄마다 빨간 단추를 깔지 않고, 왼쪽으로 밀어 지운다 (지우기 전에 한 번 묻는다)
struct SavedLoginsView: View {
    let sites: SiteAccountsModel
    @State private var forgetting: SiteAccountsModel.SavedSite?

    var body: some View {
        List {
            Section {
                ForEach(sites.savedSites) { saved in
                    let name = sites.name(for: saved.site)
                    let status = sites.loginSites.first { $0.site == saved.site }
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: DS.Settings.textSpacing) {
                                Text(name)
                                    .font(DS.Settings.titleFont)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                if !saved.summary.isEmpty {
                                    Text(saved.summary)
                                        .font(DS.Settings.captionFont)
                                        .foregroundStyle(DS.Colors.textSecondary)
                                }
                            }
                        } icon: {
                            SiteIconView(site: saved.site, name: name, macHost: status?.host, size: 28)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("지우기", role: .destructive) { forgetting = saved }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "지우기") { forgetting = saved }
                }
            } footer: {
                Text("로그인할 때 저장을 켠 아이디와 비밀번호예요. 이 아이폰의 키체인에만 있고, Face ID로 확인한 뒤에만 꺼내 써요. 다른 기기로 옮겨지지 않고, 맥이나 AI에게 저장되지 않아요. 지우려면 줄을 왼쪽으로 미세요.")
            }
        }
        .settingsListStyle()
        .tint(IntegrationsView.point)
        .navigationTitle("저장된 로그인")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog(
            forgetting.map { "\(sites.name(for: $0.site)) 저장한 로그인 값 지우기" } ?? "",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { saved in
            Button("지우기", role: .destructive) { sites.forgetSaved(saved.site) }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("이 아이폰에 저장해 둔 아이디와 비밀번호를 지워요. 맥의 로그인 상태는 그대로예요. 다음에 로그인할 때는 직접 입력해야 해요.")
        }
        // 다 지우면 돌아갈 곳이 없으니 빈 화면에 알린다
        .overlay {
            if sites.savedSites.isEmpty {
                ContentUnavailableView("저장된 로그인이 없어요", systemImage: "key")
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        IntegrationsView(mail: MailAccountsModel(), sites: SiteAccountsModel())
    }
}
#endif
