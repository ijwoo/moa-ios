import SwiftData
import SwiftUI
import UIKit

/// 내 정보 탭: 할 일과 맥 / 환경 설정 / 연결 및 계정 / 데이터 및 권한 / 앱 정보 (D51, D147: 맨 위 제목과 내 기록 묶음은 뺐다).
///
/// 시스템 설정 화면처럼 묶음 목록 한 장이다. 줄에는 이름과 지금 값만 두고, 고르기·긴 설명·세부 상태는 눌러서 들어간 화면에 둔다.
/// 표시하는 숫자와 상태는 모두 실제 데이터·코드 동작에서 온다.
/// 브라우저 로그인·메일 계정은 연동 센터(`IntegrationsView`)에서 다룬다. 여기에는 줄마다 지금 상태만 보인다 (D49).
struct ProfileView: View {
    @Query private var actionItems: [ActionItem]
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.Key.appearance) private var appearance: AppearanceMode = .system
    @AppStorage(AppSettings.Key.replyTone) private var replyTone: ReplyTone = .friendly
    @AppStorage(AppSettings.Key.space) private var spaceEnabled = false

    /// 열려 있는 화면. 대화에서 연동 센터로 바로 올 수 있게 바깥(RootView)이 들고 있는다
    @Binding var path: [ProfileDestination]
    /// 맥에 붙은 것들 (예약·맡길 수 있는 일, D120). 없으면 그 묶음을 두지 않는다
    var session: AskSession?
    var skills: SkillsModel?
    /// 새 대화에서 이 말을 보낸다 (예약의 "+", 맡길 수 있는 일)
    var onAsk: (String) -> Void = { _ in }
    /// 대화 탭으로 간다 (예약 결과·올리기를 대화로 열었을 때)
    var onOpenChat: () -> Void = {}
    @State private var showingTasks = false
    @State private var storageBytes: Int64 = 0
    @State private var permissions = PermissionItem.current()
    @State private var mail = MailAccountsModel()
    @State private var sites = SiteAccountsModel()
    /// 맥에서 상태를 한 번이라도 받아 보았는지 (받기 전에 "맥 연결 필요"가 먼저 보이지 않게)
    @State private var mailLoaded = false
    @State private var sitesLoaded = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    macSection
                    preferencesSection
                    connectionsSection
                    dataSection
                    aboutSection
                }
                .settingsListStyle()
                #if DEBUG
                // 화면 확인용: 아래쪽 묶음부터 보이게 연다
                .task {
                    guard DemoData.arguments.contains("-demoBottom") else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    proxy.scrollTo(Self.lastRowID, anchor: .bottom)
                }
                #endif
            }
            // 맨 위 제목은 보이지 않는다 (D147). 이름은 길게 누른 뒤로 단추 목록·손쉬운 사용에만 쓴다
            .navigationTitle("내 정보")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ProfileDestination.self) { destination in
                switch destination {
                case .privacy: PrivacyDetailView()
                case .integrations: IntegrationsView(mail: mail, sites: sites)
                case .appearance:
                    SettingChoiceList(
                        title: "화면 모드", options: AppearanceMode.allCases, selection: $appearance,
                        label: \.title, detail: { $0 == .system ? "아이폰의 화면 모드를 따라가요" : nil }
                    )
                case .accent: AccentChoiceView()
                case .replyTone:
                    SettingChoiceList(
                        title: "답변 말투", options: ReplyTone.allCases, selection: $replyTone,
                        label: \.title, footer: "질문 탭에서 받는 답의 말투예요. 메일 초안이나 작업 내용은 바뀌지 않아요."
                    )
                case .permissions: PermissionsView()
                case .licenses: LicensesView()
                case .routines:
                    if let session { RoutinesView(model: session.routines, session: session, onAsk: onAsk, onOpened: onOpenChat) }
                case .skills:
                    if let session, let skills { SkillsView(skills: skills, session: session, onAsk: onAsk) }
                case .memory:
                    if let session { MemoryView(model: session.memory) }
                }
            }
            .sheet(isPresented: $showingTasks) {
                TasksView().presentationDragIndicator(.visible)
            }
            .task {
                guard let session else { return }
                await session.routines.load()
                await session.memory.load()
                await skills?.load()
            }
            .onAppear { refresh() }
            .task {
                await mail.load()
                mailLoaded = true
            }
            .task {
                await sites.load()
                sitesLoaded = true
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refresh()
                    Task { await mail.load() }
                    Task { await sites.load() }
                }
            }
        }
    }

    private static let lastRowID = "profile.lastRow"

    enum ProfileDestination: Hashable { case privacy, integrations, appearance, accent, replyTone, permissions, licenses, routines, skills, memory }

    // MARK: - 맥 (D120: 사이드바에도 있는 화면을 내 정보에서도 찾는다)

    @ViewBuilder
    private var macSection: some View {
        let hasMac = session?.hasAgent == true
        let hasMacRows = hasMac && (
            session?.routines.isOffered == true || skills?.isOffered == true
                || session?.memory.isOffered == true
        )
        // 내 공간이 꺼져 있으면 할 일 전체 목록으로 가는 곳이 여기뿐이다 (할 일 탭이 없어졌다)
        if hasMacRows || !spaceEnabled {
            Section("할 일과 맥") {
                if !spaceEnabled {
                    Button {
                        showingTasks = true
                    } label: {
                        SettingsRow(icon: .clipboardList, title: "할 일", value: TaskOverview(items: actionItems).hasTasks ? "\(TaskOverview(items: actionItems).open)개 남음" : "")
                    }
                    .foregroundStyle(DS.Colors.textPrimary)
                }
                if let session, hasMac {
                    if session.routines.isOffered {
                        NavigationLink(value: ProfileDestination.routines) {
                            SettingsRow(icon: .history, title: "예약", value: session.routines.routines.isEmpty ? "" : "\(session.routines.routines.count)개")
                        }
                    }
                    if skills?.isOffered == true {
                        NavigationLink(value: ProfileDestination.skills) {
                            SettingsRow(icon: .listChecks, title: "맡길 수 있는 일")
                        }
                    }
                    // 오래 가는 기억 (D151): 맥이 대화에서 정리해 둔 요약과 지난 대화
                    if session.memory.isOffered {
                        NavigationLink(value: ProfileDestination.memory) {
                            SettingsRow(icon: .messagesSquare, title: "기억")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 환경 설정

    /// 사용자가 바꾸는 설정. 새 설정은 AppSettings에 추가한 뒤 여기에 줄을, `ProfileDestination`에 고르는 화면을 더한다
    private var preferencesSection: some View {
        Section("환경 설정") {
            NavigationLink(value: ProfileDestination.appearance) {
                SettingsRow(icon: .sunMoon, title: "화면 모드", value: appearance.title)
            }
            // 강조색 (D144): 앱 전체와 앱 아이콘의 포인트 색. 아이콘 자리에 지금 색의 견본을 둔다
            NavigationLink(value: ProfileDestination.accent) {
                LabeledContent {
                    Text(AppTheme.shared.accent.name).foregroundStyle(DS.Colors.textSecondary)
                } label: {
                    Label {
                        Text("강조색").font(DS.Settings.titleFont).foregroundStyle(DS.Colors.textPrimary)
                    } icon: {
                        AccentSwatch(choice: AppTheme.shared.accent, size: 18)
                    }
                }
            }
            NavigationLink(value: ProfileDestination.replyTone) {
                SettingsRow(icon: .messageCircle, title: "답변 말투", value: replyTone.title)
            }
            // 내 공간 (D94): 켠 사람에게만 탭이 생긴다
            SettingsRow(icon: .sparkles, title: "내 공간", subtitle: "말한 대로 카드를 모아 두는 탭을 더해요") {
                Toggle("내 공간", isOn: $spaceEnabled)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
            }
        }
    }

    // MARK: - 연결 및 계정 (D49)

    /// 브라우저 로그인과 메일 계정은 서로 다른 연결이다 (줄을 나누고 상태도 따로 보인다). 둘 다 연동 센터에서 다룬다
    private var connectionsSection: some View {
        Section {
            NavigationLink(value: ProfileDestination.integrations) {
                SettingsRow(icon: .globe, title: "브라우저 로그인", subtitle: "\(MailKeeper.name) 브라우저의 사이트 로그인") {
                    connectionValue(loaded: sitesLoaded, ConnectionSummary.browser(supported: sites.isSupported, sites: sites.sites))
                }
            }
            .accessibilityHint("연동 센터에서 사이트 로그인 상태를 봅니다")
            NavigationLink(value: ProfileDestination.integrations) {
                SettingsRow(icon: .mail, title: "메일 계정", subtitle: "메일을 보낼 때 쓰는 내 주소") {
                    connectionValue(loaded: mailLoaded, ConnectionSummary.mail(supported: mail.isSupported, accounts: mail.accounts))
                }
            }
            .accessibilityHint("연동 센터에서 메일 계정 상태를 봅니다")
        } header: {
            Text("연결 및 계정")
        } footer: {
            Text("계정 로그인 없이 이 기기와 내 맥에서만 동작해요.")
        }
    }

    @ViewBuilder
    private func connectionValue(loaded: Bool, _ text: String) -> some View {
        if loaded {
            Text(text).foregroundStyle(DS.Colors.textSecondary)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("확인 중")
        }
    }

    // MARK: - 데이터 및 권한

    private var dataSection: some View {
        Section {
            NavigationLink(value: ProfileDestination.privacy) {
                SettingsRow(icon: .shieldCheck, title: "데이터 처리 방식")
            }
            .accessibilityHint("데이터가 저장·전송되는 방식을 자세히 봅니다")
            NavigationLink(value: ProfileDestination.permissions) {
                SettingsRow(icon: .keyRound, title: "권한", value: PermissionSummary.text(permissions + [PushCenter.shared.permissionItem].compactMap { $0 }))
            }
            SettingsRow(icon: .hardDrive, title: "저장 공간") {
                Text(storageBytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("데이터 및 권한")
        } footer: {
            Text("저장 공간은 녹음 파일의 크기예요. 회의를 지우면 그 회의의 녹음 파일도 함께 지워져요.")
        }
    }

    // MARK: - 앱 정보

    private var aboutSection: some View {
        Section("앱 정보") {
            SettingsRow(icon: .info, title: "버전") {
                Text(Self.versionString)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            NavigationLink(value: ProfileDestination.licenses) {
                SettingsRow(icon: .fileText, title: "오픈소스 라이선스")
            }
            .id(Self.lastRowID)
        }
    }

    // MARK: - 동작

    private func refresh() {
        storageBytes = AudioStorage.totalBytes()
        permissions = PermissionItem.current()
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

/// 내 정보의 "브라우저 로그인"·"메일 계정" 줄에 보이는 지금 상태. 맥이 알린 것만 말하고, 메일 주소는 넣지 않는다
enum ConnectionSummary {
    /// 맥에 닿지 않았거나 맥이 이 기능을 알리지 않을 때 (연결된 것처럼 말하지 않는다)
    static let needsMac = "\(MailKeeper.name) 연결 필요"

    /// 로그인된 사이트 이름 ("네이버"). 없으면 "로그인 안 됨". 메일 연결은 로그인이 아니라 세지 않는다 (메일 쪽에서 센다)
    static func browser(supported: Bool, sites: [SiteStatus]) -> String {
        guard supported else { return needsMac }
        let names = sites.filter { $0.kind == .login && $0.status == .loggedIn }.map(\.name)
        if names.isEmpty { return "로그인 안 됨" }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count)곳 로그인됨"
    }

    /// 보낼 수 있게 연결된 계정 수 ("2개 연결됨"). 없으면 "연결 안 됨"
    static func mail(supported: Bool, accounts: [MailAccount]) -> String {
        guard supported else { return needsMac }
        let ready = accounts.filter { $0.status == .ready }.count
        return ready == 0 ? "연결 안 됨" : "\(ready)개 연결됨"
    }
}

#if DEBUG
#Preview {
    @Previewable @State var path: [ProfileView.ProfileDestination] = []
    ProfileView(path: $path)
        .modelContainer(PreviewData.container)
}
#endif
