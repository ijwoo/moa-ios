import SwiftUI
import UIKit

// 사이트 로그인 화면 (D48): 채팅의 "로그인" 카드와 연동 센터가 함께 쓴다.
// 맥이 같은 형식으로 진행하는 "메일 연결"도 이 화면으로 한다 (D52). 그때는 정해 둔 말이 다르다 (`SiteLoginCopy`).
//
// 아이디·비밀번호가 지나가는 길은 여기 하나뿐이다: 이 화면의 입력칸 → 맥의 로그인 입력 요청.
// 채팅 입력창·대화 기록·로그·모델에게 가는 요청에는 들어가지 않고, 맥에는 저장하지 않는다.
// 보낸 뒤와 화면을 떠날 때 입력칸을 비운다.
//
// 이 아이폰에는 사용자가 "로그인되면 이 아이폰에 저장"을 켰을 때만, 로그인된 뒤에 키체인에 둔다 (D78, `LoginVault`).
// 저장해 둔 값은 Face ID 확인 뒤에만 꺼내고, 저장할 때와 같은 호스트의 화면에만 넣는다.

struct SiteLoginSheet: View {
    @State private var flow: SiteLoginFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// 입력칸 이름 → 지금 넣은 값. 보내는 순간 비운다
    @State private var values: [String: String] = [:]
    @FocusState private var focus: String?
    /// 크게 보고 있는 그림
    @State private var zoomed: ZoomedPicture?
    /// 손 넘기기 화면을 띄웠는지 (D149)
    @State private var showingBrowser = false

    init(flow: SiteLoginFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    switch flow.screen {
                    case .opening:
                        progress(flow.copy.opening, detail: "몇 초 걸려요.")
                    case .working(let message):
                        progress(message, detail: nil)
                    case .input(let login):
                        inputForm(login)
                    case .approval(let login):
                        approval(login)
                    case .choice(let login):
                        choice(login)
                    case .done:
                        done
                    case .stopped(let title, let detail, let canRetry):
                        stopped(title: title, detail: detail, canRetry: canRetry)
                    }
                    if flow.isOffline, flow.isActive {
                        notice(flow.copy.offline)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.easeOut(duration: 0.2), value: flow.screen)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DS.Colors.background)
            .navigationTitle(flow.copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.isActive || flow.isStarting ? "취소" : "닫기") {
                        flow.close()
                        dismiss()
                    }
                }
            }
        }
        // 진행 중에는 쓸어내려 닫히지 않는다 (닫으면 맥의 로그인도 그만둔다. "취소"로만 닫는다)
        .interactiveDismissDisabled(flow.isActive || flow.isStarting)
        .task {
            if flow.login == nil { await flow.start() }
            #if DEBUG
            await demoFill()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // 휴대폰에서 승인하고 돌아오면 바로 지금 상태를 받는다 (그 사이에도 맥에서는 로그인이 이어진다)
            if phase == .active { Task { await flow.refresh() } }
        }
        .onChange(of: flow.login?.step) {
            // 화면이 바뀌면 앞 화면에 넣던 값은 버린다
            values = [:]
        }
        // 화면을 떠나면 입력한 것을 지우고, 끝나지 않은 로그인은 그만둔다
        .onDisappear {
            values = [:]
            flow.close()
        }
    }

    // MARK: - 입력

    private func inputForm(_ login: SiteLogin) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.section) {
            CardSection(footer: flow.copy.inputFooter(
                for: login, keeps: flow.keeps && flow.canKeep, saved: flow.savedInfo != nil, unlock: flow.unlockName
            )) {
                if !login.message.isEmpty {
                    // 그림을 보고 답하는 화면에서는 이 글이 물음이다. 그림 바로 위에 굵게 둔다
                    Text(login.message)
                        .font(login.image == nil ? .subheadline : .headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let data = login.image, let image = UIImage(data: data) {
                    // 그림은 카드 너비만큼 크게 보여 준다 (영수증처럼 글씨가 작은 그림을 읽고 답해야 할 수 있다)
                    Button { zoomed = ZoomedPicture(image: image) } label: {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: Self.pictureMaxHeight)
                            .padding(8)
                            // 사이트가 준 색 그대로 봐야 읽힌다 (어두운 화면에서도 흰 바탕)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: DS.Radius.inner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("보안 확인 그림")
                    .accessibilityHint("누르면 크게 봅니다. 그림을 보고 아래 칸에 답을 넣어 주세요")
                    Label("그림을 누르면 크게 볼 수 있어요", systemImage: "plus.magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else if login.fields.contains(where: { $0.name == "captcha" }) {
                    notice("그림을 받지 못했어요. 취소한 뒤 다시 시도해 주세요.")
                }
                if let text = Self.repeatHint(for: login) {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if flow.copy.kind == .login,
                          let text = Self.againHint(for: login, passwordSent: flow.passwordSent, siteName: flow.siteName) {
                    // 같은 로그인 칸이 또 나오면 오류나 되풀이로 보인다 (실제로 사용자가 여기서 취소했다). 눈에 띄게 알린다
                    Label {
                        Text(text)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(DS.Colors.accent)
                    }
                    .font(.subheadline)
                }
                savedButton(login)
                ForEach(Array(login.fields.enumerated()), id: \.element.id) { index, item in
                    field(item, isLast: index == login.fields.count - 1, login: login)
                }
                // 틀렸다는 말은 입력칸 바로 아래에 둔다 (어디를 고쳐야 하는지 눈이 바로 가게)
                if login.wasWrongInput {
                    notice(flow.copy.wrongInput)
                }
                if let text = flow.inputNotice { notice(text) }
                if let text = flow.vaultNotice { notice(text) }
                keepToggle(login)
            }
            // 입력칸이 나오면 첫 칸에 바로 쓸 수 있게 한다 (화면이 바뀔 때마다).
            // 그림을 보고 답하는 화면은 먼저 읽어야 하므로 자판을 올리지 않는다 (자판이 그림을 가린다).
            // 저장해 둔 값을 쓸 수 있는 화면도 올리지 않는다 (버튼 하나로 끝날 수 있다)
            .task(id: login.step) {
                // "Face ID로 다시 로그인"을 눌러 연 로그인 (D122): 저장해 둔 값이 칸을 모두 채우면 바로 얼굴 확인을 띄워 넣어 보낸다 (한 번만)
                if flow.takesSavedAutomatically(login) {
                    useSaved(login)
                    return
                }
                if login.image == nil, flow.savedNames(for: login).isEmpty { focus = login.fields.first?.name }
            }
            .sheet(item: $zoomed) { PictureViewer(image: $0.image) }

            VStack(alignment: .leading, spacing: DS.Spacing.item) {
                Button { submit(login) } label: {
                    Text(flow.copy.submitTitle(for: login)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit(login))
                remaining(login)
            }
        }
    }

    /// 저장해 둔 값을 꺼내는 버튼 (D78): 이 화면의 칸에 넣을 수 있는 값이 있을 때만 보인다
    @ViewBuilder
    private func savedButton(_ login: SiteLogin) -> some View {
        if !flow.savedNames(for: login).isEmpty {
            let fillsAll = flow.savedFillsAll(login)
            Button { useSaved(login) } label: {
                Label(flow.copy.savedButton(fillsAll: fillsAll), systemImage: flow.unlockName == "Touch ID" ? "touchid" : "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(flow.isUnlocking)
            .accessibilityHint(flow.copy.savedButtonHint(unlock: flow.unlockName, fillsAll: fillsAll))
        }
    }

    /// "로그인되면 이 아이폰에 저장" 스위치 (D78): 저장할 수 있는 기기에서, 아이디나 비밀번호를 묻는 화면에만 보인다
    @ViewBuilder
    private func keepToggle(_ login: SiteLogin) -> some View {
        if flow.offersKeeping(for: login) {
            Toggle(flow.copy.keepToggle, isOn: $flow.keeps)
                .font(.subheadline)
                .foregroundStyle(DS.Colors.textPrimary)
                .tint(DS.Colors.accent)
        }
    }

    /// 얼굴 확인 뒤에 저장해 둔 값을 쓴다: 칸을 모두 채우면 바로 보내고, 아니면 칸에 넣어 두고 나머지를 받는다
    private func useSaved(_ login: SiteLogin) {
        focus = nil
        Task {
            let saved = await flow.savedValues(for: login)
            guard !saved.isEmpty else { return }
            if Set(saved.keys) == Set(login.fields.map(\.name)) {
                values = [:]
                await flow.submit(saved)
            } else {
                for (name, value) in saved { values[name] = value }
                focus = login.fields.first { saved[$0.name] == nil }?.name
            }
        }
    }

    @ViewBuilder
    private func field(_ item: SiteLogin.Field, isLast: Bool, login: SiteLogin) -> some View {
        let binding = Binding(get: { values[item.name] ?? "" }, set: { values[item.name] = $0 })
        let title = item.label.isEmpty ? Self.fallbackLabel(item.name) : item.label
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            Group {
                if item.secret || item.name == "password" {
                    // 아이폰의 암호 저장 제안이 뜨지 않게 한다: 암호 앱에 넣으면 iCloud로 다른 기기에 옮겨질 수 있다.
                    // 저장은 사용자가 켰을 때 앱이 직접, 이 기기에만 한다 (D78)
                    SecureField(title, text: binding)
                        .textContentType(.oneTimeCode)
                } else if item.name == "code" {
                    TextField(title, text: binding)
                        .keyboardType(Self.keyboard(for: item.name))
                        .textContentType(.oneTimeCode)
                } else {
                    TextField(title, text: binding)
                        .keyboardType(Self.keyboard(for: item.name))
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: item.name)
            .submitLabel(isLast ? .done : .next)
            .onSubmit {
                if isLast {
                    submit(login)
                } else if let index = login.fields.firstIndex(of: item) {
                    focus = login.fields[index + 1].name
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: DS.minTouch)
            .background(DS.Colors.inset, in: RoundedRectangle(cornerRadius: DS.Radius.inner, style: .continuous))
        }
    }

    /// 칸마다 쓰는 자판. 그림에 대한 답(`captcha`)은 한글 낱말일 수도 있어서 자판을 묶지 않는다
    /// (빌드 24는 영문 전용이라 한글 자판으로 바꿀 수 없었다). 숫자 자판은 인증 번호(`code`)만
    static func keyboard(for name: String) -> UIKeyboardType {
        switch name {
        case "id": .emailAddress
        case "code", "birth", "phone": .numberPad
        default: .default
        }
    }

    /// 그림이 아주 길어도 화면을 다 차지하지 않게 한다 (더 크게는 눌러서 본다)
    static let pictureMaxHeight: CGFloat = 520

    /// 보안문자와 함께 비밀번호를 또 물을 때, 왜 다시 넣는지 알린다 (보낸 값은 화면에 남기지 않는다)
    static func repeatHint(for login: SiteLogin) -> String? {
        let names = Set(login.fields.map(\.name))
        guard names.contains("captcha"), names.contains("password") else { return nil }
        return "비밀번호와 보안문자를 함께 입력해 주세요. 보낸 비밀번호는 화면에 남기지 않아서 다시 넣어야 해요."
    }

    /// 비밀번호를 낸 뒤에 사이트가 로그인 칸을 한 번 더 보여 줄 때 (틀렸다는 표시 없이), 오류가 아니라고 알린다.
    /// 실제 네이버는 그림 확인 뒤에 "다시 로그인해 주세요"라며 로그인 화면을 또 보여 주었다 (2026-11-12)
    static func againHint(for login: SiteLogin, passwordSent: Bool, siteName: String) -> String? {
        let names = Set(login.fields.map(\.name))
        guard passwordSent, !login.wasWrongInput, names.contains("password"), !names.contains("captcha") else { return nil }
        return "\(siteName)에서 한 번 더 로그인해 달라고 해요. 오류가 아니에요. 보낸 아이디·비밀번호는 화면에 남기지 않아서 다시 넣어야 해요."
    }

    static func fallbackLabel(_ name: String) -> String {
        switch name {
        case "id": "아이디"
        case "password": "비밀번호"
        case "captcha": "보안문자"
        case "code": "인증 번호"
        case "name": "이름"
        case "birth": "생년월일 (8자리)"
        case "phone": "휴대폰 번호"
        default: "입력"
        }
    }

    /// 보낼 값: 아이디·보안문자·인증 번호는 앞뒤 공백을 떼고, 비밀번호는 넣은 그대로
    static func cleaned(_ values: [String: String], for login: SiteLogin) -> [String: String] {
        var out: [String: String] = [:]
        for item in login.fields {
            let raw = values[item.name] ?? ""
            if SiteLogin.digitNames.contains(item.name) {
                // 생년월일·휴대폰 번호: 숫자만 보낸다 ("1990-01-02", "010 1234 5678"처럼 넣어도 된다)
                out[item.name] = raw.filter { $0.isASCII && $0.isNumber }
            } else {
                out[item.name] = item.secret || item.name == "password" ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    private func canSubmit(_ login: SiteLogin) -> Bool {
        Self.cleaned(values, for: login).values.allSatisfy { !$0.isEmpty && $0.count <= SiteLoginFlow.maxValueLength }
    }

    private func submit(_ login: SiteLogin) {
        guard canSubmit(login) else { return }
        let sending = Self.cleaned(values, for: login)
        // 보낸 뒤에는 화면에도 남기지 않는다 (틀렸으면 다시 넣는다)
        values = [:]
        focus = nil
        Task { await flow.submit(sending) }
    }

    // MARK: - 그 밖의 상태

    private func progress(_ text: String, detail: String?) -> some View {
        CardSection {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .accessibilityElement(children: .combine)
        }
    }

    private func approval(_ login: SiteLogin) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.item) {
            CardSection(footer: flow.copy.approvalFooter) {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.Colors.accent)
                        .accessibilityHidden(true)
                    Text(login.message.isEmpty ? flow.copy.approvalFallback : login.message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("승인을 기다리고 있어요")
                            .font(.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .accessibilityElement(children: .combine)
            }
            remaining(login)
        }
    }

    private func choice(_ login: SiteLogin) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.item) {
            CardSection(footer: login.handover == nil ? flow.copy.choiceFooter : flow.copy.handoverFooter(for: login)) {
                let texts = flow.copy.choiceTexts(for: login)
                if let headline = texts.headline {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(texts.body)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // 손 넘기기 (D149): 글자로 답할 수 없는 확인 문제는 맥의 브라우저 화면을 띄워 직접 푼다 (작업 질문 카드와 같은 화면)
                if let handover = login.handover {
                    Button { showingBrowser = true } label: {
                        Label("브라우저 열기", systemImage: "macbook.and.iphone").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Chat.userBubble)
                    .controlSize(.large)
                    .accessibilityHint("맥의 브라우저 화면을 띄워 직접 누르고 씁니다")
                    .fullScreenCover(isPresented: $showingBrowser) {
                        HandoverView(agent: flow.handoverAgent, handover: handover, choices: login.choices) { answer in
                            pick(answer, in: login)
                        }
                    }
                }
                ForEach(login.choices, id: \.self) { item in
                    Button {
                        pick(item, in: login)
                    } label: {
                        Text(item).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            if let text = flow.inputNotice { notice(text) }
            remaining(login)
        }
    }

    /// 고른 것을 보낸다. 손 넘기기의 "그만하기"는 답으로 보내지 않고 로그인을 그만둔다 (닫기와 같다, D149)
    private func pick(_ item: String, in login: SiteLogin) {
        if flow.isHandoverStop(item, in: login) {
            showingBrowser = false
            flow.close()
            dismiss()
        } else {
            Task { await flow.choose(item) }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.item) {
            CardSection {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(DS.Colors.success)
                        .accessibilityHidden(true)
                    Text(flow.copy.doneTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(flow.asksToKeep ? flow.copy.doneDetail : flow.copy.doneDetail(phone: flow.phoneKeeping, unlock: flow.unlockName))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .accessibilityElement(children: .combine)
            }
            if flow.asksToKeep {
                // 저장 스위치를 켜지 않고 로그인됐다: 지금 저장할지 묻는다 (D122). 답하지 않고 닫으면 저장하지 않는다
                CardSection {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(flow.copy.keepAskTitle, systemImage: flow.unlockName == "Touch ID" ? "touchid" : "faceid")
                            .font(.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(flow.copy.keepAskDetail(unlock: flow.unlockName))
                            .font(.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button { flow.keepOffered() } label: {
                    Text("저장").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    flow.declineKeeping()
                    dismiss()
                } label: {
                    Text("저장 안 함").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button { dismiss() } label: {
                    Text("완료").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func stopped(title: String, detail: String, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.item) {
            CardSection {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(DS.Colors.warning)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let time = flow.stoppedAt {
                        // 무슨 일이 있었는지 맥의 기록과 맞춰 볼 수 있게 시각을 남긴다
                        Text("멈춘 시각 \(time.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .accessibilityElement(children: .combine)
            }
            if canRetry {
                Button {
                    Task { await flow.start() }
                } label: {
                    Text("다시 시도").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(flow.isStarting)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func remaining(_ login: SiteLogin) -> some View {
        if let text = Self.remainingText(login.expiresIn) {
            Text(text)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 남은 시간. 1분 넘게 남았으면 분으로만 보여 준다 (조회할 때마다 숫자가 흔들리지 않게)
    static func remainingText(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return seconds >= 60 ? "남은 시간 약 \(seconds / 60)분" : "남은 시간 \(seconds)초"
    }

    #if DEBUG
    /// 화면 확인용 (`-demoSiteLoginAuto`): 첫 입력 화면을 가상 값으로 채워 보낸다.
    /// `-demoMailSetupAuto N`: 메일 연결에서 물음 N개에 가상 값으로 답한다 (고르는 물음은 첫 선택지)
    private func demoFill() async {
        if flow.copy.kind == .mailSetup, var left = Int(DemoData.value(after: "-demoMailSetupAuto") ?? "") {
            for _ in 0..<80 {
                guard left > 0 else { return }
                switch flow.screen {
                case .input(let login):
                    await flow.submit(Dictionary(uniqueKeysWithValues: login.fields.map { ($0.name, $0.name == "id" ? "me@naver.test" : "demo") }))
                    left -= 1
                case .choice(let login):
                    if let first = login.choices.first { await flow.choose(first) }
                    left -= 1
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return
        }
        guard DemoData.arguments.contains("-demoSiteLoginAuto") else { return }
        for _ in 0..<40 {
            if case .input(let login) = flow.screen, login.step == 1 {
                await flow.submit(["id": "minsu_demo", "password": DemoData.value(after: "-demoSiteLoginAuto") ?? "demo"])
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
    #endif
}

extension SiteStatus.Status {
    /// 내 정보의 상태 배지
    var badge: (text: String, tone: StatusBadge.Tone) {
        switch self {
        case .loggedIn: ("로그인됨", .positive)
        case .loggedOut: ("로그인 안 됨", .muted)
        case .unknown: ("확인 필요", .muted)
        }
    }
}

// MARK: - 그림 크게 보기

private struct ZoomedPicture: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 보안 확인 그림을 두 손가락으로 벌려 크게 본다. 그림은 여기서도 어디에 저장하지 않는다
private struct PictureViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableImage(image: image)
                .background(Color.white)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("그림 크게 보기")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.backgroundColor = .white
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = "보안 확인 그림"
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.zoomed = view
        // 두 번 두드리면 크게, 다시 두드리면 처음 크기로
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var zoomed: UIView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomed }

        @objc func toggle(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: zoomed)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
