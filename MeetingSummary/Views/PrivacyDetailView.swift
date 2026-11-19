import SwiftUI

/// 데이터가 저장·처리·전송되는 방식. 실제 코드 동작과 같아야 한다.
///
/// 근거 코드: 저장 — SwiftData 모델·`AudioStorage` / 인식 — `TranscriptionService`(SpeechAnalyzer) /
/// 요약 전송 — `SummaryRequest` / 질문 전송 — `AskRequest`·`AskContextBuilder` / 기기 ID — `SummaryAPI.post`
/// 서버 기록 — `proxy/src/server.js` `log()` / 삭제 — `MeetingsView.delete`, `AskSession.delete`.
/// 맥 에이전트 — `AgentHTTPClient.message`·`AgentContext`(8000자), `AskSession.converse`(맥이 먼저 받고 회의 질문만 Claude로),
/// `AskSession.history(for:)`(Claude에는 Claude가 답한 대화만).
/// 맥의 대화 판단 — `DialogPlaceModel`·`MacAgentFacts`(맥이 `dialog_cloud`를 알릴 때만 Claude 설명, `dialog_context`·`web_lookup`에 따라 회의 자료·웹 검색 줄. 목록은 맥의 `docs/API.md` 표).
/// 알림 — `PushCenter`·`PushNotice`(맥이 `push`를 알릴 때만 줄이 생긴다. 실리는 것은 맥의 `docs/design/push.md`와 맞춘 문장·번호뿐).
/// 코드가 바뀌면 이 화면도 함께 고친다.
struct PrivacyDetailView: View {
    /// 지금 내 맥이 대화 판단을 어디서 하는지. 맥이 Claude에 맡긴다고 알릴 때만 그 설명으로 바뀐다 (D60)
    @State private var dialog = DialogPlaceModel()

    var body: some View {
        List {
            Section {
                fact(.audioLines, "녹음한 음성 파일")
                fact(.alignLeft, "받아쓴 대화, 요약, 결정 사항, 할 일, 중요 표시")
                fact(.messagesSquare, "질문 탭 대화 기록")
            } header: {
                Text("이 기기에만 저장돼요")
            } footer: {
                Text("계정이나 클라우드 동기화가 없어서, 다른 기기로 옮겨지지 않아요.")
            }

            Section {
                fact(.mic, "음성을 텍스트로 바꾸는 일 (한국어, 기기 내 음성 인식)")
                fact(.mic, "모아와 통화할 때 내 말을 듣고, 답을 소리로 읽는 일", note: "바꾼 글만 내 맥으로 가요. 통화 소리는 따로 저장하지 않아요")
            } header: {
                Text("기기 안에서 처리돼요")
            } footer: {
                Text("음성은 어디로도 보내지 않아요.")
            }

            Section {
                fact(.sparkles, "요약할 때", note: "그 회의의 제목, 받아쓴 대화와 각 문장의 시각, 중요 표시 시각")
                fact(.messageCircleQuestion, "질문할 때", note: "질문, 최근 대화 몇 개, 질문과 관련 있는 회의의 대화 일부와 요약, 나머지 회의의 제목·날짜·주제")
            } header: {
                Text("이럴 때만 텍스트가 전송돼요")
            } footer: {
                Text("텍스트는 중계 서버를 거쳐 Anthropic Claude로 전달돼요. 요청 횟수 제한을 위해 기기 식별자(Apple이 앱 개발사별로 주는 값)도 함께 보내요.")
            }

            Section {
                ForEach(dialog.facts.rows) { row in
                    fact(row.icon, row.text, note: row.note)
                }
            } header: {
                Text("맥 에이전트를 연결했다면")
            } footer: {
                Text(dialog.facts.footer)
            }

            Section("중계 서버에는") {
                fact(.fileSearch, "대화 내용을 저장하지 않아요")
                fact(.clipboardList, "요청 시각, 처리 시간, 글자 수, 사용량 같은 운영 기록만 남겨요")
            }

            Section("지우는 방법") {
                fact(.trash, "회의 탭에서 회의를 왼쪽으로 밀어 지우면 음성 파일, 대화, 요약, 할 일이 함께 지워져요")
                fact(
                    .history, "질문 대화는 질문 탭의 대화 기록에서 밀어서 지울 수 있어요",
                    note: "질문 대화에 근거로 인용된 문장은 대화 기록에 함께 저장돼서, 회의를 지워도 그 대화를 지우기 전까지 남아요."
                )
                fact(.listChecks, "미리알림에 넣은 할 일은 미리알림 앱에 남아요. 미리알림 앱에서 지워 주세요")
                fact(.squareX, "앱을 지우면 이 기기에 저장된 모든 데이터가 지워져요")
            }
        }
        .settingsListStyle()
        .navigationTitle("데이터 처리 방식")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await dialog.load() }
    }

    /// 사실 한 줄 (+ 그 줄에 딸린 보충 설명)
    private func fact(_ icon: Lucide, _ text: String, note: String? = nil) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(DS.Settings.readingFont)
                    .foregroundStyle(DS.Colors.textPrimary)
                if let note {
                    Text(note)
                        .font(DS.Settings.captionFont)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        } icon: {
            LucideIcon(icon).foregroundStyle(DS.Colors.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { PrivacyDetailView() }
}
