import SwiftUI

// 메일 계정 연결: 채팅의 "메일 계정 연결" 카드와 내 정보의 "메일 연동" 카드가 함께 쓰는 화면과 모델.
//
// 앱 비밀번호가 지나가는 길은 여기 하나뿐이다: 이 화면의 입력칸 → 작업을 실행하는 쪽의 계정 연결 요청.
// 채팅 입력창·대화 기록·로그·모델에게 가는 요청에는 들어가지 않고, 이 아이폰에도 저장하지 않는다.

/// 메일 비밀번호를 보관하는 곳. 지금은 작업을 실행하는 맥이다.
/// 나중에 서버가 그 일을 맡게 되면 여기 글만 바꾼다 (화면과 흐름은 그대로 쓴다)
enum MailKeeper {
    /// "○○에서 로그인해 보고 있어요"
    static let name = "맥"
    /// "○○에만 보관해요"
    static let store = "맥의 키체인"
    /// 보낼 수 있는 내 주소는 실행하는 쪽 설정에서만 정한다 (앱 토큰만으로 보낼 곳이 늘지 않게)
    static let addressSetupGuide = "보낼 수 있는 내 메일 주소가 아직 없어요. 맥의 에이전트 설정에 내 주소를 먼저 넣어야 해요."
}

/// 연결할 수 있는 메일 서비스
enum MailProvider: String, CaseIterable, Identifiable {
    case naver, gmail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naver: "네이버 메일"
        case .gmail: "Gmail"
        }
    }

    var addressHint: String {
        switch self {
        case .naver: "아이디@naver.com"
        case .gmail: "아이디@gmail.com"
        }
    }

    /// 앱 비밀번호를 만드는 순서. 계정의 진짜 비밀번호가 아니라, 메일 앱용으로 따로 만드는 비밀번호다
    var steps: [String] {
        switch self {
        case .naver:
            [
                "네이버 내정보 → 보안설정에서 2단계 인증을 켜요.",
                "같은 화면의 '애플리케이션 비밀번호 관리'에서 비밀번호를 만들어요.",
                "네이버 메일 → 환경설정 → POP3/IMAP 설정에서 IMAP/SMTP를 '사용함'으로 바꿔요.",
            ]
        case .gmail:
            [
                "Google 계정의 보안에서 2단계 인증을 켜요.",
                "앱 비밀번호 페이지에서 비밀번호를 만들어요.",
                "만들어진 16자리를 아래 칸에 넣어요.",
            ]
        }
    }

    /// 앱 비밀번호를 만드는 페이지 (확인된 주소만)
    var passwordPage: URL? {
        switch self {
        case .naver: nil
        case .gmail: URL(string: "https://myaccount.google.com/apppasswords")
        }
    }

    /// 주소로 서비스를 짐작한다 (모르면 nil)
    static func guess(from address: String) -> MailProvider? {
        let domain = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        if domain.hasPrefix("gmail.") || domain.hasPrefix("googlemail.") { return .gmail }
        if domain.hasPrefix("naver.") { return .naver }
        return nil
    }
}

/// 메일 계정 연결 화면. 앱 비밀번호를 받아 `connect`로 넘기고, 돌아온 로그인 결과만 보여 준다.
struct MailConnectSheet: View {
    typealias Connect = (_ provider: String, _ address: String, _ password: String) async throws -> MailAccount.Status

    let connect: Connect
    /// 로그인까지 확인된 뒤 (화면은 스스로 닫힌다)
    var onConnected: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var provider: MailProvider
    @State private var address: String
    @State private var password = ""
    @State private var isBusy = false
    @State private var problem: String?
    @FocusState private var focus: Field?

    private enum Field { case address, password }

    init(provider: MailProvider = .naver, address: String = "", connect: @escaping Connect, onConnected: @escaping () -> Void = {}) {
        self.connect = connect
        self.onConnected = onConnected
        _provider = State(initialValue: provider)
        _address = State(initialValue: address)
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 붙여 넣을 때 섞이는 공백은 뺀다 (Gmail은 네 자리씩 띄어서 보여 준다)
    private var cleanPassword: String { password.filter { !$0.isWhitespace } }
    private var canSubmit: Bool {
        !isBusy && !cleanPassword.isEmpty && trimmedAddress.contains("@") && trimmedAddress.contains(".")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    CardSection(
                        footer: "앱 비밀번호는 이 아이폰에 저장하지 않아요. 바로 \(MailKeeper.store)에 넣고 그곳에만 보관해요. 대화 기록이나 AI에게는 전달되지 않아요."
                    ) {
                        Picker("메일 서비스", selection: $provider) {
                            ForEach(MailProvider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)

                        field("메일 주소") {
                            TextField(provider.addressHint, text: $address)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .address)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                        }

                        field("앱 비밀번호") {
                            // 아이폰의 암호 저장 제안이 뜨지 않게 한다 (이 비밀번호는 아이폰에 두지 않는다)
                            SecureField("메일 앱용으로 만든 비밀번호", text: $password)
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .password)
                                .submitLabel(.done)
                        }

                        Text("계정의 진짜 비밀번호는 넣지 마세요. 아래 순서로 만든 앱 비밀번호만 넣어요.")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CardSection(title: "\(provider.title) 앱 비밀번호 만드는 법", spacing: 10) {
                        ForEach(Array(provider.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.footnote.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(DS.Colors.accent)
                                    .frame(width: 16)
                                    .accessibilityHidden(true)
                                Text(step)
                                    .font(.subheadline)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(index + 1)단계. \(step)")
                        }
                        if let page = provider.passwordPage {
                            Button {
                                openURL(page)
                            } label: {
                                Label("앱 비밀번호 페이지 열기", systemImage: "arrow.up.right.square")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(minHeight: DS.minTouch)
                            .accessibilityHint("사파리에서 엽니다")
                        }
                    }

                    VStack(alignment: .leading, spacing: DS.Spacing.item) {
                        if let problem {
                            Label {
                                Text(problem)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                            }
                            .font(.subheadline)
                        }
                        Button(action: submit) {
                            HStack(spacing: 8) {
                                if isBusy { ProgressView().controlSize(.small) }
                                Text(isBusy ? "\(MailKeeper.name)에서 로그인해 보고 있어요…" : "연결")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSubmit)
                        if isBusy {
                            Text("메일 서버에 실제로 로그인해 보느라 20초쯤 걸릴 수 있어요.")
                                .font(.footnote)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DS.Colors.background)
            .navigationTitle("메일 계정 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }.disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onChange(of: address) {
            if let guessed = MailProvider.guess(from: address), guessed != provider { provider = guessed }
        }
        .onChange(of: provider) { problem = nil }
        // 화면을 떠나면 입력한 비밀번호를 지운다
        .onDisappear { password = "" }
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            content()
                .padding(.horizontal, 12)
                .frame(minHeight: DS.minTouch)
                .background(DS.Colors.inset, in: RoundedRectangle(cornerRadius: DS.Radius.inner, style: .continuous))
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let secret = cleanPassword
        // 보낸 뒤에는 화면에도 남기지 않는다 (실패하면 다시 넣는다)
        password = ""
        problem = nil
        isBusy = true
        focus = nil
        Task {
            defer { isBusy = false }
            do {
                let status = try await connect(provider.rawValue, trimmedAddress, secret)
                if status == .ready {
                    onConnected()
                    dismiss()
                } else {
                    problem = Self.problem(for: status, provider: provider)
                }
            } catch {
                problem = Self.problem(for: error)
            }
        }
    }

    /// 로그인 결과를 사용자에게 보여 줄 문장으로 (결과는 종류만 온다)
    static func problem(for status: MailAccount.Status, provider: MailProvider) -> String {
        switch status {
        case .ready:
            ""
        case .authFailed:
            provider == .naver
                ? "로그인하지 못했어요. 주소와 앱 비밀번호를 확인하고, 네이버 메일 환경설정에서 IMAP/SMTP가 '사용함'인지도 봐 주세요."
                : "로그인하지 못했어요. 주소와 앱 비밀번호를 확인해 주세요."
        case .unreachable:
            "메일 서버에 연결하지 못했어요. 잠시 뒤에 다시 해 주세요. 넣은 비밀번호는 보관하지 않았어요."
        case .notSet, .unknown:
            "연결을 확인하지 못했어요. 다시 해 주세요."
        }
    }

    static func problem(for error: Error) -> String {
        switch error as? AgentError {
        case .conflict: "지금 연결된 \(MailKeeper.name)에서는 앱으로 메일 계정을 연결하는 기능을 아직 쓸 수 없어요."
        case .unreachable: "\(MailKeeper.name)에 연결할 수 없어요. 연결을 확인하고 다시 해 주세요."
        case .notAllowed: "보낼 수 있는 내 주소로 등록되지 않은 주소예요. 주소를 다시 확인해 주세요. 넣은 비밀번호는 보관하지 않았어요."
        case .rateLimited: "짧은 시간에 여러 번 시도했어요. 10분쯤 뒤에 다시 해 주세요."
        default: "연결하지 못했어요. 잠시 뒤에 다시 해 주세요."
        }
    }
}

/// 내 정보의 "메일 연동" 카드가 쓰는 계정 목록. 맥이 메일 보내기를 지원한다고 알릴 때만 카드가 나타난다
@MainActor
@Observable
final class MailAccountsModel {
    private let agent: (any AgentProviding)?
    /// 맥이 본인 주소로 메일 보내기를 지원하는지 (지원하지 않으면 카드를 보여 주지 않는다)
    private(set) var isSupported = false
    /// 앱에서 계정을 연결할 수 있는지
    private(set) var canConnect = false
    private(set) var accounts: [MailAccount] = []
    /// 맥이 계정마다 다시 로그인해 보는 중
    private(set) var isChecking = false
    /// 계정 목록을 받지 못했는지
    private(set) var loadFailed = false

    init(agent: (any AgentProviding)? = AgentClient.fromEnvironment()) {
        self.agent = agent
    }

    /// 계정 목록을 받는다. `check`면 맥이 지금 다시 로그인해 본다 (몇 초 걸린다)
    func load(check: Bool = false) async {
        guard let agent, !isChecking else { return }
        guard await agent.isReachable() else {
            loadFailed = isSupported
            return
        }
        isSupported = await agent.supports(AgentFeature.sendSelf)
        canConnect = await agent.supports(AgentFeature.mailConnect)
        guard isSupported else { return }
        isChecking = check
        defer { isChecking = false }
        do {
            accounts = try await agent.mailAccounts(check: check)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// 계정을 연결한다. 비밀번호는 넘기기만 하고 이 객체에 남기지 않는다
    func connect(provider: String, address: String, password: String) async throws -> MailAccount.Status {
        guard let agent else { throw AgentError.unreachable }
        let result = try await agent.connectMail(provider: provider, address: address, password: password)
        accounts = result
        loadFailed = false
        return result.first { $0.address.lowercased() == address.lowercased() }?.status ?? .unknown
    }
}

extension MailAccount.Status {
    /// 계정 목록의 상태 배지
    var badge: (text: String, tone: StatusBadge.Tone) {
        switch self {
        case .ready: ("연결됨", .positive)
        case .authFailed: ("로그인 실패", .warning)
        case .unreachable: ("연결 안 됨", .warning)
        case .notSet: ("연결 필요", .muted)
        case .unknown: ("확인 필요", .muted)
        }
    }

    /// 다시 연결하면 풀리는 상태인지
    var needsConnect: Bool { self == .authFailed || self == .notSet }
}
