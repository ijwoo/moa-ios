import Contacts
import Foundation

// 연락처에서 받는 사람 찾기 (D89).
// 주소록 전체를 보내지 않는다: 내가 쓴 말에 이름이 나온 사람의 이름과 메일 주소만 내 맥으로 간다.
// 그 사람에게 메일 주소가 없으면 이름만 간다 (D92) — 맥이 "연락처에 없다"가 아니라 "주소가 없다"고 되묻게.
// 읽은 주소록은 어디에도 저장하지 않는다 (대화 기록에도, 파일에도).

/// 주소록의 한 사람. 메일 주소가 없는 사람도 있다 (`emails`가 비어 있다)
struct ContactPerson: Equatable, Sendable {
    struct Email: Equatable, Sendable {
        /// "직장"·"집" 같은 이름표 (없으면 빈 글)
        var label: String = ""
        var address: String
    }

    /// 보이는 이름 (사람 이름, 없으면 회사 이름)
    var name: String
    /// 별명 ("김팀장"처럼 따로 적어 둔 이름)
    var nickname: String = ""
    var emails: [Email] = []
}

enum ContactAccess: Equatable, Sendable {
    case allowed
    /// 아직 묻지 않았다
    case notAsked
    case denied
}

/// 주소록을 읽는 곳 (실제: 아이폰의 연락처. 테스트·데모: 지어낸 사람들)
protocol ContactReading: Sendable {
    func access() -> ContactAccess
    /// 권한을 묻는다. 허용했으면 true
    func request() async -> Bool
    /// 이름이 있는 사람들 (메일 주소가 없는 사람도 온다)
    func people() async -> [ContactPerson]
}

/// 말에 나온 사람 찾기. 모두 이 기기 안에서 한다
enum ContactMatch {
    /// 한 번에 맥에 알리는 사람 수 (맥과 맞춘 값)
    static let limit = 50

    /// 이름에서 말에 나올 만한 조각: 전체, 띄어 쓴 마디, 한글 세 글자 이름의 뒤 두 글자("김철수" → "철수").
    /// 맥이 이름을 찾는 방식과 같게 맞췄다 (두 글자보다 짧은 조각은 쓰지 않는다)
    static func keys(for name: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",()/·"))
        let parts = name.components(separatedBy: separators).filter { $0.count >= 2 }
        var keys = [name.filter { !$0.isWhitespace }] + parts
        for part in parts where part.count == 3 && part.unicodeScalars.allSatisfy(isHangul) {
            keys.append(String(part.dropFirst()))
        }
        var seen = Set<String>()
        return keys.map { $0.lowercased() }.filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(scalar.value) }

    /// 맥이 받는 메일 주소 꼴인지 (맥은 하나라도 어긋나면 요청 전체를 거절한다)
    static func isAddress(_ text: String) -> Bool {
        text.count <= 254 && text.wholeMatch(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/) != nil
    }

    /// 맥에 알릴 이름인지 (1~50자)
    static func isName(_ text: String) -> Bool { !text.isEmpty && text.count <= 50 }

    /// 말에 이름이 나온 사람들의 `{이름: 메일 주소}`.
    /// 주소가 여럿인 사람은 "김철수 (직장)"처럼 이름표를 붙여 따로 알린다 — 어느 주소인지 앱이 고르지 않는다
    static func mentioned(in text: String, people: [ContactPerson]) -> [String: String] {
        found(in: text, people: people).withEmail
    }

    /// 말에 이름이 나왔지만 **메일 주소가 없는** 사람들의 이름 (D92). 같은 이름에 주소가 있는 사람이 있으면 뺀다
    static func mentionedWithoutEmail(in text: String, people: [ContactPerson]) -> [String] {
        found(in: text, people: people).withoutEmail
    }

    /// 말에 나온 사람을 한 번에 찾는다: 주소 있는 사람은 `{이름: 주소}`, 없는 사람은 이름만
    static func found(in text: String, people: [ContactPerson]) -> (withEmail: [String: String], withoutEmail: [String]) {
        let said = text.lowercased().filter { !$0.isWhitespace }
        guard said.count >= 2 else { return ([:], []) }
        var hits: [(length: Int, name: String, emails: [ContactPerson.Email])] = []
        var bare: [(length: Int, name: String)] = []
        for person in people {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nickname = person.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let byName = keys(for: name).filter(said.contains).map(\.count).max() ?? 0
            let byNickname = keys(for: nickname).filter(said.contains).map(\.count).max() ?? 0
            guard max(byName, byNickname) > 0 else { continue }
            // 별명으로만 불렀으면 그 별명으로 알린다 (맥이 내 말의 이름과 맞춰 볼 수 있게)
            let shown = byNickname > byName || name.isEmpty ? nickname : name
            let emails = person.emails
                .map { ContactPerson.Email(label: $0.label, address: $0.address.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { isAddress($0.address) }
            guard isName(shown) else { continue }
            if emails.isEmpty {
                bare.append((max(byName, byNickname), shown))
            } else {
                hits.append((max(byName, byNickname), shown, emails))
            }
        }
        // 길게 맞은 이름부터, 같으면 이름 순서로 (늘 같은 결과가 나오게)
        hits.sort { $0.length != $1.length ? $0.length > $1.length : $0.name < $1.name }
        var found: [String: String] = [:]
        outer: for hit in hits {
            for (index, email) in hit.emails.enumerated() {
                guard found.count < limit else { break outer }
                var key = hit.name
                if hit.emails.count > 1 { key += " (\(email.label.isEmpty ? "\(index + 1)" : email.label))" }
                // 같은 이름이 또 있으면 번호를 붙인다 (같은 주소면 한 번만)
                if found[key] == email.address { continue }
                var number = 2
                var unique = key
                while found[unique] != nil {
                    unique = "\(key) \(number)"
                    number += 1
                }
                guard isName(unique) else { continue }
                found[unique] = email.address
            }
        }
        // 주소 없는 사람: 주소 있는 사람과 이름이 같으면 뺀다 (맥도 주소 있는 쪽을 쓴다)
        let taken = Set(hits.map(\.name))
        bare.sort { $0.length != $1.length ? $0.length > $1.length : $0.name < $1.name }
        var names: [String] = []
        for person in bare where !taken.contains(person.name) && !names.contains(person.name) && names.count < limit {
            names.append(person.name)
        }
        return (found, names)
    }

    /// 메일을 부탁하는 말처럼 보이는지. 연락처 권한을 **처음** 물을 때만 쓴다 (아무 말에나 묻지 않게)
    static func looksLikeMail(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["메일", "mail", "보내", "전달"].contains(where: lowered.contains)
    }
}

/// 아이폰의 연락처. 필요한 칸(이름, 별명, 회사, 메일 주소)만 읽는다 — 전화번호·주소·메모는 읽지 않는다
struct SystemContacts: ContactReading {
    func access() -> ContactAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func request() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    func people() async -> [ContactPerson] {
        await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            var people: [ContactPerson] = []
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
                // 메일 주소가 없는 사람도 읽는다 (D92). 이름도 주소도 없는 항목은 쓸 데가 없다
                guard !contact.emailAddresses.isEmpty || !name.isEmpty || !contact.nickname.isEmpty else { return }
                let emails = contact.emailAddresses.map {
                    ContactPerson.Email(
                        label: $0.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "", address: $0.value as String
                    )
                }
                people.append(ContactPerson(name: name, nickname: contact.nickname, emails: emails))
            }
            return people
        }.value
    }
}

#if DEBUG
/// 지어낸 주소록 (테스트·데모용. 실제 연락처를 읽지 않고 권한도 묻지 않는다)
final class MockContacts: ContactReading, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ContactAccess
    private let grants: Bool
    private let book: [ContactPerson]
    private var asked = 0
    private var read = 0

    /// 권한을 물은 횟수, 주소록을 읽은 횟수
    var requests: Int { lock.withLock { asked } }
    var reads: Int { lock.withLock { read } }

    init(access: ContactAccess = .allowed, grants: Bool = true, people: [ContactPerson] = MockContacts.demo) {
        state = access
        self.grants = grants
        book = people
    }

    /// 지어낸 사람들 (주소는 없는 도메인 `.test`)
    static let demo: [ContactPerson] = [
        ContactPerson(name: "김하늘", nickname: "김팀장", emails: [.init(label: "직장", address: "haneul.kim@mail.test")]),
        ContactPerson(name: "이바다", emails: [.init(label: "직장", address: "bada@work.test"), .init(label: "집", address: "bada@home.test")]),
        ContactPerson(name: "박노을", emails: [.init(address: "noeul@mail.test")]),
        // 메일 주소가 없는 사람 (D92)
        ContactPerson(name: "최구름"),
    ]

    /// 실행 인자 `-demoContacts [ask|denied]`: 지어낸 주소록을 쓴다 (ask: 아직 묻지 않음, denied: 꺼 둠). 없으면 주소록을 쓰지 않는다
    @MainActor
    static func fromArguments() -> MockContacts? {
        guard DemoData.arguments.contains("-demoContacts") else { return nil }
        switch DemoData.value(after: "-demoContacts") {
        case "ask": return MockContacts(access: .notAsked)
        case "denied": return MockContacts(access: .denied)
        default: return MockContacts()
        }
    }

    func access() -> ContactAccess { lock.withLock { state } }

    func request() async -> Bool {
        lock.withLock {
            asked += 1
            state = grants ? .allowed : .denied
            return grants
        }
    }

    func people() async -> [ContactPerson] {
        lock.withLock {
            read += 1
            return book
        }
    }
}
#endif
