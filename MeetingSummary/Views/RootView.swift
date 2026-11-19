import SwiftData
import SwiftUI

/// 최상위 화면: 질문 · 회의 · (내 공간) · 할 일 · 내 정보 탭. 내 공간은 내 정보에서 켠 사람에게만 보인다 (D94). 녹음은 질문 탭의 녹음 버튼에서 전체 화면으로 띄운다.
struct RootView: View {
    /// 대화 · 내 공간 · 활동 · 나 + 오른쪽에 떨어진 검색 (D120). 회의 탭·할 일 탭은 없앴다:
    /// 회의는 활동과 검색에서, 할 일은 내 공간 카드(또는 내 공간을 끈 사람은 "나")와 검색에서 연다
    private enum TabID: Hashable { case ask, space, activity, profile, search }

    @State private var selection: TabID = Self.initialTab
    @State private var isRecording = Self.startsRecording
    /// 내 정보 탭에서 열려 있는 화면. 다른 탭에서 연동 센터로 바로 보낼 수 있게 여기서 들고 있는다
    @State private var profilePath: [ProfileView.ProfileDestination] = Self.initialProfilePath
    /// 대화. 질문 탭과 사이드바가 함께 쓴다
    @State private var session = AskSession()
    /// 질문 탭의 사이드바 (D53). 열리면 탭 막대까지 화면 전체를 옆으로 밀어야 해서 여기서 감싼다 (D55)
    @State private var sidebar = ChatSidebarModel()
    /// 맥이 할 수 있는 일 목록 (사이드바의 "맡길 수 있는 일")
    @State private var skills = SkillsModel()
    /// 내 공간 (D94). 내 정보에서 켰을 때만 탭이 보인다
    @State private var space = SpaceModel()
    @AppStorage(AppSettings.Key.space) private var spaceEnabled = false
    /// 처음 한 번 보이는 화면 (D97). "내 공간 시작하기"를 누르면 내 공간을 켜고 그 탭으로 간다
    @AppStorage(AppSettings.Key.onboarded) private var onboarded = false
    @State private var showsOnboarding = Onboarding.shouldShow(
        done: UserDefaults.standard.bool(forKey: AppSettings.Key.onboarded), arguments: ProcessInfo.processInfo.arguments
    )
    /// 맥이 보내는 알림 (D67)
    private let push = PushCenter.shared
    /// 알림을 눌러 들어온 작업. 질문 탭이 그 카드로 간 뒤 비운다
    @State private var pushedTaskID: String?
    /// 내 공간 카드의 단추가 대화로 보내는 말 (D99). 질문 탭이 새 대화에서 보낸 뒤 비운다
    @State private var pendingAsk: String?
    /// 할 일 전체 목록과 회의 목록 (탭 대신 시트로, D120)
    @State private var showingTasks = Self.opensTasks
    @State private var showingMeetings = Self.opensMeetings

    private static var opensTasks: Bool {
        #if DEBUG
        DemoData.value(after: "-demoTab") == "tasks"
        #else
        false
        #endif
    }

    private static var opensMeetings: Bool {
        #if DEBUG
        DemoData.value(after: "-demoTab") == "meetings"
        #else
        false
        #endif
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    private static var startsRecording: Bool {
        #if DEBUG
        DemoData.arguments.contains("-demoRecording")
        #else
        false
        #endif
    }

    private static var initialTab: TabID {
        #if DEBUG
        switch DemoData.value(after: "-demoTab") {
        case "activity", "meetings": return .activity
        case "search": return .search
        case "space": return .space
        case "profile": return .profile
        default: return .ask
        }
        #else
        return .ask
        #endif
    }

    private static var initialProfilePath: [ProfileView.ProfileDestination] {
        #if DEBUG
        if DemoData.arguments.contains("-demoPrivacy") { return [.privacy] }
        if DemoData.arguments.contains("-demoIntegrations") { return [.integrations] }
        switch DemoData.value(after: "-demoProfileScreen") {
        case "appearance": return [.appearance]
        case "accent": return [.accent]
        case "tone": return [.replyTone]
        case "permissions": return [.permissions]
        case "licenses": return [.licenses]
        case "memory": return [.memory]
        default: break
        }
        #endif
        return []
    }

    var body: some View {
        // 사이드바는 화면 위에 덮이지 않는다. 탭 막대까지 화면 전체를 오른쪽으로 밀며 들어온다 (D55)
        ChatSidebarHost(session: session, model: sidebar, skills: skills) {
            tabs
        }
        .accessibilityHidden(showsOnboarding)
        .overlay {
            if showsOnboarding {
                MoaOnboardingView(onStart: startSpace)
                    .transition(.opacity)
            }
        }
        // 처음 화면은 늘 어두운 바탕이다: 밝은 모드의 검은 상태 막대 글자가 묻히지 않게 그동안 감춘다
        .statusBarHidden(showsOnboarding)
        .onChange(of: selection) { sidebar.isOpen = false }
        // 홈 화면 위젯을 눌렀다 (moa://space, D109): 내 공간 탭으로. 위젯을 둔 사람이니 꺼져 있으면 켠다
        .onOpenURL { url in
            guard url.scheme == "moa", url.host() == "space" else { return }
            spaceEnabled = true
            sidebar.isOpen = false
            selection = .space
        }
        // 내 공간을 끄면 그 탭이 사라진다: 보고 있었다면 내 정보에 머문다
        .onChange(of: spaceEnabled) { _, enabled in
            if !enabled, selection == .space { selection = .profile }
        }
        .task {
            // 대화 기록을 먼저 붙인다 (D120): 활동·검색에서 대화를 연 뒤에 대화 탭이 처음 열리며 붙으면
            // 마지막 대화가 다시 열려, 방금 연 대화를 덮었다
            session.attach(modelContext)
            await skills.load()
            await push.refresh()
            #if DEBUG
            // 개발용: -demoSidebar — 사이드바를 연 모습
            if DemoData.arguments.contains("-demoSidebar") {
                try? await Task.sleep(for: .seconds(DemoData.value(after: "-demoSidebar").flatMap { Double($0) } ?? 1))
                sidebar.isOpen = true
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // 다른 앱에 다녀온 사이 맥의 준비 상태가 바뀌었을 수 있다
            if phase == .active {
                Task {
                    await skills.load()
                    // 설정에서 알림을 켜거나 껐을 수 있다. 맥에 등록해 둔 것도 그에 맞춘다
                    await push.refresh()
                }
            }
        }
        // 알림을 눌러 들어왔다 (앱이 꺼져 있었으면 화면이 뜬 뒤에 받는다)
        .onChange(of: push.pending, initial: true) {
            if let notice = push.pending { open(notice) }
        }
        // 지금 보고 있는 대화의 알림은 배너로 띄우지 않는다
        .modifier(VisibleConversationReporter(
            showsChat: selection == .ask && !isRecording && scenePhase == .active,
            sidebar: sidebar, session: session, push: push
        ))
        // 처음 일을 맡겼을 때 알림을 받을지 묻는다 (맥이 알림을 보낼 수 있을 때만, 한 번만)
        .onChange(of: session.status) { _, status in
            if status == .working { Task { await push.askPermission() } }
        }
        .fullScreenCover(isPresented: $isRecording) {
            NavigationStack {
                RecordingFlowView()
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            // 아이콘은 한 덩어리 모양으로 맞추고, 고른 탭만 채운다 (D47). 탭 막대 자체는 시스템 유리 그대로다
            Tab(value: TabID.ask) {
                AskView(
                    session: session, sidebar: sidebar, skills: skills,
                    onRecord: { isRecording = true }, onOpenIntegrations: openIntegrations, pushedTaskID: $pushedTaskID,
                    pendingAsk: $pendingAsk
                )
            } label: {
                tabLabel("대화", "bubble.left", .ask)
            }
            if spaceEnabled {
                Tab(value: TabID.space) {
                    SpaceView(
                        model: space, weather: Self.spaceWeather, calendar: Self.spaceCalendar,
                        // 할 일 탭이 없어져, 카드의 "전체 보기"는 할 일 목록을 시트로 연다 (D120)
                        onOpenTasks: { showingTasks = true },
                        // 카드의 단추: 맥이 준 말을 대화 탭의 새 대화에서 보낸다 (예약 화면의 "+"와 같은 길)
                        onSay: askInChat,
                        // "지금 가져오기"가 대화로 넘어갔으면 그 대화를 대화 탭에서 연다 (D128)
                        onOpenRun: { run in
                            Task {
                                if await session.openRoutineRun(id: run.id) == .opened { selection = .ask }
                            }
                        }
                    )
                } label: {
                    tabLabel("내 공간", "square.grid.2x2", .space)
                }
            }
            Tab(value: TabID.activity) {
                ActivityView(session: session, model: session.activity, onOpenChat: openChat)
            } label: {
                tabLabel("활동", "clock", .activity)
            }
            // 사람이 처리해야 할 것(승인·질문 대기)만 센다. 보내기 대기는 사람이 할 일이 아니라 넣지 않는다
            .badge(session.waitingTasks.count)
            Tab(value: TabID.profile) {
                ProfileView(
                    path: $profilePath, session: session, skills: skills, onAsk: askInChat,
                    onOpenChat: { openChat(nil) }
                )
            } label: {
                tabLabel("나", "person", .profile)
            }
            Tab(value: TabID.search, role: .search) {
                SearchView(session: session, activity: session.activity, onOpenChat: openChat, onAsk: askInChat)
            } label: {
                tabLabel("검색", "magnifyingglass", .search)
            }
        }
        // 탭 막대의 고른 탭은 고른 강조색으로 (D144)
        .tint(DS.Colors.accent)
        // 스크롤해도 탭 막대를 접지 않는다. 대화는 입력창 위에서 끝나고, 입력창과 탭 막대 뒤는 대화 바탕색이다 (D38을 D83에서 고침)
        .tabBarMinimizeBehavior(.never)
        // 탭을 바꿀 때 가볍게 (D114)
        .sensoryFeedback(.selection, trigger: selection)
        .sheet(isPresented: $showingTasks) {
            TasksView().presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingMeetings) {
            MeetingsView().presentationDragIndicator(.visible)
        }
    }

    /// 대화 탭으로 가서 그 작업의 카드로 간다 (활동·검색에서 연 대화, D120)
    private func openChat(_ taskID: String?) {
        sidebar.screen = nil
        selection = .ask
        pushedTaskID = taskID
    }

    /// 대화 탭의 새 대화에서 이 말을 보낸다
    private func askInChat(_ text: String) {
        // 대화 탭을 아직 연 적이 없으면 대화 기록이 붙기 전이다: 먼저 붙여야 새 대화에서 보낸다 (보던 대화에 섞이지 않게)
        session.attach(modelContext)
        sidebar.screen = nil
        pendingAsk = text
        selection = .ask
    }

    /// 내 공간의 날씨 카드가 쓰는 날씨. 가짜 맥과 함께일 때는 앱이 만든 가상 날씨다 (위치를 묻지도, 밖으로 나가지도 않는다)
    private static var spaceWeather: any WeatherProviding {
        #if DEBUG
        if DemoData.arguments.contains("-demoAgent"), let mock = MockWeatherService.fromArguments() { return mock }
        #endif
        return AppleWeatherService()
    }

    /// 내 공간의 오늘 일정 카드가 읽는 캘린더 (D95). 가짜 맥과 함께일 때는 지어낸 일정이다 (실제 캘린더를 읽지도, 권한을 묻지도 않는다)
    private static let spaceCalendar: any DayEventsProviding = {
        #if DEBUG
        if DemoData.arguments.contains("-demoAgent") { return MockDayEvents.fromArguments() }
        #endif
        return SystemDayEvents()
    }()

    /// 알림을 눌러 들어왔을 때: 질문 탭에서 그 대화를 열고 그 작업 카드로 간다. 대화를 찾지 못하면 질문 탭만 연다.
    /// 내용은 알림에 실려 오지 않는다. 대화를 열면 끝나지 않은 작업의 지금 상태를 맥에서 다시 받는다 (`AskSession.resumeAgent`)
    private func open(_ notice: PushNotice) {
        push.pending = nil
        selection = .ask
        sidebar.isOpen = false
        sidebar.screen = nil
        // 앱이 막 켜졌으면 대화 기록을 아직 붙이기 전일 수 있다 (나중에 붙으면 마지막 대화가 다시 열린다)
        session.attach(modelContext)
        // 로그인이 풀린 사이트 (D122): 그 사이트에 저장해 둔 값이 있으면 대화 화면에서 바로 다시 로그인한다.
        // 없으면(소셜 로그인·맥 화면의 크롬 사이트·저장하지 않은 사이트) "나" 탭으로 — 연동 센터에서 다시 로그인한다
        if notice.kind == .loginExpired {
            if let site = notice.site, SiteLoginFlow.quickUnlock(for: site) != nil {
                session.reloginSite = site
            } else {
                selection = .profile
            }
            return
        }
        // 예약이 돈 결과 (D91): 알림의 번호는 작업이 아니라 실행 기록이다. 그 결과를 맥에서 받아 대화로 연다
        if notice.kind == .routineResult, let runID = notice.taskID {
            Task {
                let result = await session.openRoutineRun(id: runID)
                if let text = result.notice { session.routines.notice = text }
                // 열지 못했으면 예약 화면에서 까닭을 보여 준다
                if result != .opened { sidebar.screen = .routines }
            }
            return
        }
        guard let taskID = notice.taskID else {
            // 작업 번호가 없는 알림: 그 대화만 연다
            if let id = notice.conversationID, session.agentConversationID != id, session.canSwitchConversation,
               let conversation = PushCenter.conversation(for: notice, in: modelContext) {
                session.open(conversation)
            }
            return
        }
        Task {
            // 이 기기에 없는 대화의 작업: 예약이 돌며 맥에서 생긴 작업일 수 있다 (D91). 그 실행을 찾아 대화로 연다
            if let id = notice.conversationID, session.agentConversationID != id,
               PushCenter.conversation(for: notice, in: modelContext) == nil,
               session.routines.isOffered, session.canSwitchConversation,
               await session.openRoutineRun(taskID: taskID) == .opened {
                pushedTaskID = taskID
                return
            }
            // 그 밖에는 작업을 그 대화에서 연다. 기기에 저장된 대화라도 그 작업이 기록에 없으면 맥에서 받아 붙인다
            // (D113: 맥이 같은 대화에 새 작업을 만들면 저장된 기록만으로는 승인 카드가 보이지 않았다)
            if await session.openTaskInItsConversation(id: taskID, conversationID: notice.conversationID) == .opened {
                pushedTaskID = taskID
            }
        }
    }

    /// 처음 화면의 "내 공간 시작하기": 내 공간을 켜고 그 탭으로 간다. 다시 보이지 않는다 (내 공간은 내 정보에서 끌 수 있다)
    private func startSpace() {
        onboarded = true
        spaceEnabled = true
        selection = .space
        withAnimation(.easeOut(duration: 0.35)) { showsOnboarding = false }
    }

    /// 내 정보 탭의 연동 센터를 연다 (대화의 로그인 완료 카드에서)
    private func openIntegrations() {
        profilePath = [.integrations]
        selection = .profile
    }

    /// 탭은 아이콘만 보인다 (글자 없음). 고르지 않은 탭은 선, 고른 탭은 채운 아이콘.
    /// 이름은 화면에 없어도 VoiceOver가 읽게 접근성 이름으로 남긴다
    private func tabLabel(_ title: String, _ symbol: String, _ id: TabID) -> some View {
        Image(systemName: symbol)
            .environment(\.symbolVariants, selection == id ? .fill : .none)
            .accessibilityLabel(title)
    }
}

#if DEBUG
#Preview {
    RootView()
        .modelContainer(PreviewData.container)
}
#endif

/// 질문 탭에서 지금 보고 있는 대화의 맥 쪽 번호를 알림 센터에 알린다. 다른 탭이나 다른 화면을 보고 있으면 nil.
/// 사이드바의 여닫힘은 여기서만 읽는다 (D148): `RootView`의 body가 읽으면 사이드바를 여닫는 순간 앱 전체를 다시 그려 움직임이 멈칫했다
private struct VisibleConversationReporter: ViewModifier {
    /// 질문 탭을 보고 있고, 녹음 중이 아니고, 앱이 앞에 있다
    let showsChat: Bool
    let sidebar: ChatSidebarModel
    let session: AskSession
    let push: PushCenter

    func body(content: Content) -> some View {
        let id = showsChat && !sidebar.isOpen && sidebar.screen == nil ? session.agentConversationID : nil
        content.onChange(of: id, initial: true) { push.visibleConversationID = id }
    }
}
