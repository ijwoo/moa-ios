import Foundation

/// 보고의 답이 "번호 붙은 항목 여러 줄"일 때, 그 글을 항목으로 나눈 것 (D57).
///
/// 맥의 모델은 읽은 항목을 `1. 이름: 가상문구 | 금액: 7,400원 | 날짜: … | 상태: …`처럼 한 줄에 몰아 쓴다.
/// 그대로 보이면 긴 줄이 접혀 어디까지가 한 건인지, 무엇이 금액인지 읽기 어렵다.
///
/// 여기서는 나눠 놓기만 한다. 글자를 고치거나 채우지 않고, 빼는 것은 칸 이름(`이름:`·`금액:`·`날짜:`·`상태:`)뿐이다.
/// 모양이 조금이라도 다르면 nil을 준다 → 화면은 글을 그대로 보여 준다 (틀리게 나누느니 그대로 둔다).
struct ReportRecords: Equatable, Sendable {
    struct Record: Equatable, Sendable, Identifiable {
        /// 글에 적힌 번호 (1부터)
        let id: Int
        /// 무엇인지 (상품·가게 이름)
        let title: String
        /// 금액 (있을 때만). 오른쪽에 따로 보여 준다
        let amount: String?
        /// 나머지 칸 (날짜·상태 등). 이름을 아는 칸은 값만, 모르는 칸은 "이름 값"
        let details: [String]

        /// 화면 읽기용 한 문장
        var spoken: String {
            (["\(id)번", title] + (amount.map { [$0] } ?? []) + details).joined(separator: ", ")
        }
    }

    /// 항목 앞의 글 ("최근 결제 3건이에요.")
    var intro: [String]
    var records: [Record]
    /// 항목 뒤의 글
    var outro: [String]

    /// 글이 번호 붙은 항목 줄들이면 나눠서 준다.
    ///
    /// 맞는 모양: 줄마다 `번호. 칸 | 칸 | …` (번호는 1부터 차례로, 칸은 둘 이상), 항목 줄 사이에 다른 줄이 없다.
    /// 칸은 `이름: 값`이거나 값만 있다. 항목 앞뒤의 다른 줄은 그대로 앞글·뒷글이 된다.
    static func parse(_ text: String) -> ReportRecords? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var intro: [String] = [], outro: [String] = [], records: [Record] = []
        for line in lines {
            if let (number, body) = numbered(line) {
                // 번호가 차례대로가 아니거나, 뒷글 다음에 또 항목이 나오면 이 모양이 아니다
                guard outro.isEmpty, number == records.count + 1, let record = record(number, body) else { return nil }
                records.append(record)
            } else if records.isEmpty {
                intro.append(line)
            } else {
                outro.append(line)
            }
        }
        guard !records.isEmpty else { return nil }
        return ReportRecords(intro: intro, records: records, outro: outro)
    }

    // MARK: - 한 줄

    /// `3. 나머지` · `3) 나머지` → (3, "나머지")
    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: \.isWholeNumber)
        guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
        let body = rest.dropFirst()
        // 번호 뒤에 빈칸이 있어야 한다 ("3.5만원" 같은 글을 번호로 보지 않는다)
        guard body.first == " " else { return nil }
        return (number, body.trimmingCharacters(in: .whitespaces))
    }

    private struct Field {
        /// 칸 이름 (없으면 값만 있는 칸)
        let key: String?
        let value: String
    }

    private static let titleKeys: Set<String> = ["이름", "상품", "상품명", "제목", "항목", "품목", "가게", "상호", "사용처", "가맹점", "결제처", "내용"]
    /// 이름을 빼고 오른쪽에 보여 줘도 되는 금액 칸
    private static let amountKeys: Set<String> = ["금액", "결제금액", "결제 금액", "가격", "합계"]
    /// 값만 보여도 무엇인지 아는 칸 (이름을 빼고 보여 준다)
    private static let plainKeys: Set<String> = ["날짜", "일시", "일자", "시간", "결제일", "결제일시", "결제일자", "주문일", "주문일시", "상태", "결제상태", "주문상태"]

    private static func record(_ number: Int, _ body: String) -> Record? {
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var fields = parts.map(field)
        guard fields.allSatisfy({ !$0.value.isEmpty }) else { return nil }

        // 제목: 이름 칸 → 없으면 이름 없는 칸 가운데 금액이 아닌 첫 칸
        guard let titleIndex = fields.firstIndex(where: { $0.key.map(titleKeys.contains) == true })
            ?? fields.firstIndex(where: { $0.key == nil && !isAmount($0.value) }) else { return nil }
        let title = fields.remove(at: titleIndex).value

        // 금액: 금액 칸이 하나뿐일 때만 오른쪽으로 뺀다.
        // 둘 이상이면(결제 금액·할인 금액) 어느 것이 무엇인지 이름이 있어야 하므로 모두 아래 줄에 이름과 함께 둔다
        let amounts = fields.indices.filter { index in
            fields[index].key.map { $0.hasSuffix("금액") || $0.hasSuffix("가격") || $0 == "합계" } ?? isAmount(fields[index].value)
        }
        var amount: String?
        if amounts.count == 1, fields[amounts[0]].key.map(amountKeys.contains) ?? true {
            amount = fields.remove(at: amounts[0]).value
        }

        let details = fields.map { field in
            guard let key = field.key, !plainKeys.contains(key) else { return field.value }
            return "\(key) \(field.value)"
        }
        return Record(id: number, title: title, amount: amount, details: details)
    }

    /// `이름: 값` → 이름과 값. 이름은 짧고 숫자가 없어야 한다 ("18:59" 같은 시각을 이름으로 보지 않는다)
    private static func field(_ part: String) -> Field {
        guard let colon = part.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return Field(key: nil, value: part) }
        let key = part[..<colon].trimmingCharacters(in: .whitespaces)
        let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard (1...10).contains(key.count), !key.contains(where: { $0.isNumber || $0.isPunctuation }) else {
            return Field(key: nil, value: part)
        }
        return Field(key: key, value: value)
    }

    /// "7,400원" · "-1,200원" · "₩7,400" 같은 값
    private static func isAmount(_ value: String) -> Bool {
        var body = Substring(value)
        if let sign = body.first, sign == "-" || sign == "+" { body = body.dropFirst() }
        let hasUnit = body.hasSuffix("원") || body.hasPrefix("₩")
        if body.hasSuffix("원") { body = body.dropLast() }
        if body.hasPrefix("₩") { body = body.dropFirst() }
        let digits = body.trimmingCharacters(in: .whitespaces)
        return hasUnit && !digits.isEmpty && digits.allSatisfy { $0.isWholeNumber || $0 == "," }
    }
}
