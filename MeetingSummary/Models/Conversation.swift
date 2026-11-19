import Foundation
import SwiftData

/// 질문 탭의 대화 하나. 앱을 다시 열어도 남고, 기록 목록에서 다시 열 수 있다.
@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    /// 첫 질문 (기록 목록에 표시)
    var title: String
    /// 맥의 대화 담당이 준 대화 번호 (다음 메시지에 함께 보낸다). 맥이 잊었으면 새 번호로 바뀐다
    var agentConversationID: String?
    /// 사이드바 맨 위에 고정했는지 (D116). 나중에 더한 값이라 기본값이 있다 (예전 기록도 그대로 열린다)
    var isPinned: Bool = false
    /// 사이드바에 보일 마지막 말의 앞부분 (D116). 저장할 때마다 바꾼다. 예전 기록은 nil (`previewText`가 기록에서 찾는다)
    var preview: String?
    /// 이 대화를 마지막으로 본 때 (D126). 열 때·떠날 때·보고 있는 동안 저장할 때 바뀐다. 예전 기록은 nil (`updatedAt`을 대신 쓴다)
    var lastReadAt: Date?
    /// 이 대화에 마지막으로 새 소식이 생긴 때 (D126): 떠나 있는 동안 맥의 작업이 끝났거나 내 답을 기다리게 됐다
    var newsAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ChatRecord.conversation)
    var records: [ChatRecord] = []

    init(id: UUID = UUID(), title: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// 안 읽은 새 소식이 있는지 (D126): 마지막으로 본 뒤에 소식이 생겼다
    var hasUnread: Bool {
        guard let newsAt else { return false }
        return newsAt > (lastReadAt ?? updatedAt)
    }

    /// 맥 에이전트를 쓴 대화인지 (기록 목록 표시용)
    var usesAgent: Bool { records.contains { $0.engineRaw == "local" } }

    var sortedRecords: [ChatRecord] {
        records.sorted { $0.createdAt < $1.createdAt }
    }

    /// 사이드바의 아랫줄: 마지막 말의 앞부분 (한 줄)
    var previewText: String? {
        if let preview, !preview.isEmpty { return preview }
        let last = records.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.max { $0.createdAt < $1.createdAt }
        return last.map { Self.snippet($0.text) }
    }

    /// 한 줄로 줄인 글 (줄바꿈은 빈칸으로, 80자까지)
    static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(flat.prefix(80))
    }
}

/// 대화 속 질문 또는 답변 하나 (오류 메시지는 저장하지 않는다)
///
/// 맥 에이전트 대화는 `engineRaw`가 "local"이고, 에이전트 답은 roleRaw "agent" + 끝난 작업 상태(`agentData`).
@Model
final class ChatRecord {
    @Attribute(.unique) var id: UUID
    /// "user", "assistant", "agent"
    var roleRaw: String
    var text: String
    var found: Bool
    /// 근거 목록 (JSON)
    var citationsData: Data?
    /// 처리한 곳: nil·"cloud" = 회의 질문(중계 서버 → Claude), "local" = 맥 에이전트
    var engineRaw: String?
    /// 맥 에이전트 작업 상태 (JSON). 진행 중에도 저장하고 상태가 바뀌면 고친다
    var agentData: Data?
    /// 이 말에 붙인 반응 (이모지 하나). 기기에만 남고 어디에도 보내지 않는다
    var reaction: String?
    /// 대화 담당이 내 말에 단 반응 (이모지 하나, D70). 내가 붙인 반응과 따로 둔다.
    /// 말 없이 반응만 받은 말은 이것으로 "답을 받았다"고 안다
    var agentReaction: String?
    /// 답장이면 인용한 말 (JSON, `AskSession.Quote`)
    var replyData: Data?
    /// 앱에서 로그인을 마쳤다고 알린 말이면 그 사이트 ("naver"). 완료 카드로 다시 그릴 때 쓴다 (아이디·비밀번호는 없다)
    var siteLoggedIn: String?
    /// 맥을 거친 답이면 그 말을 누가 썼는지 (`ReplyWriter`의 값: "claude", "local", "mac". D62). 맥이 알려 주지 않은 말은 nil
    var writerRaw: String?
    /// 날씨 카드면 그 내용 (JSON, `WeatherCard`. D66). 받아온 날씨 값과 내가 말한 지역만 있고, 이 기기의 위치는 없다
    var weatherData: Data?
    /// 맥이 "쇼핑 화면에서 같이 보자"고 한 말이면 그 검색어 (D74). 카드를 다시 그릴 때 쓴다 (주소는 저장하지 않는다)
    var shopQuery: String?
    /// 쇼핑 화면에서 "확인해 줘"를 눌러 보낸 말이면 그때 읽어 보낸 것 (JSON, `ShopView`. D74).
    /// 상품의 공개 정보와 그 화면의 호스트·경로뿐이다 (로그인 정보나 주문 화면의 값은 없다)
    var shopViewData: Data?
    /// 사진·PDF를 붙여 보낸 말이면 무엇을 붙였는지 (JSON, `SentUploads`. D85).
    /// 종류와 PDF의 파일 이름뿐이다: 그림과 파일의 내용은 저장하지 않는다
    var uploadsData: Data?
    /// 통화 중에 주고받은 말이면 그 통화의 번호 (D137). 대화에서는 같은 번호의 말을 통화 카드 하나로 접는다
    var callID: UUID?
    var createdAt: Date

    var conversation: Conversation?

    init(id: UUID = UUID(), role: String, text: String, found: Bool = true, citationsData: Data? = nil,
         engineRaw: String? = nil, agentData: Data? = nil, createdAt: Date = .now) {
        self.id = id
        self.roleRaw = role
        self.text = text
        self.found = found
        self.citationsData = citationsData
        self.engineRaw = engineRaw
        self.agentData = agentData
        self.createdAt = createdAt
    }
}
