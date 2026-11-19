import Foundation
import LocalAuthentication
import Security

// 사이트 로그인의 아이디·비밀번호를 이 아이폰의 키체인에 두는 곳 (D78).
//
// 사용자가 "비밀번호를 폰 키체인에 저장하고 Face ID로 꺼내 쓰게 해"라고 정했다 (2026-11-15). 그 전에는 어디에도 두지 않았다.
// 사용자가 로그인 화면에서 "이 아이폰에 저장"을 켰을 때만, 그리고 그 값으로 실제로 로그인된 뒤에만 넣는다.
// - 이 기기 전용이다: 다른 기기로 옮겨지지 않고 iCloud 키체인에도 올라가지 않는다 (`ThisDeviceOnly`, 동기화 끔).
// - 꺼낼 때마다 Face ID(Touch ID)로 확인한다. 등록된 얼굴·지문이 바뀌면 그 값은 더 꺼낼 수 없다 (`biometryCurrentSet`).
//   기기 암호로 대신 여는 길은 두지 않는다.
// - 값은 맥으로 가는 로그인 입력 요청에만 쓴다. 맥에는 저장되지 않고, 대화 기록·로그·모델에게 가는 요청에는 들어가지 않는다.
// - 얼굴 확인 없이 알 수 있는 것은 "어느 사이트의 어떤 칸이, 어느 호스트의 화면에서 받은 것으로 저장돼 있다"뿐이다 (값은 없다).

/// 저장해 둔 로그인 값: 칸마다 값과, 그 값을 받았던 화면의 호스트
struct SavedLogin: Equatable, Sendable, Codable {
    struct Entry: Equatable, Sendable, Codable {
        var value: String
        /// 값을 넣었던 화면의 호스트 (맥이 알려 준 것). 호스트를 알려 주지 않는 로그인(네이버)은 nil
        var host: String?
    }

    /// 저장하는 칸. 보안문자·인증 번호는 그때그때 다른 값이라 저장하지 않는다
    static let names: Set<String> = ["id", "password"]

    /// 칸 이름 → 값
    var entries: [String: Entry]

    /// 얼굴 확인 없이 볼 수 있는 부분 (값이 없다)
    var info: SavedLoginInfo {
        SavedLoginInfo(fields: entries.keys.sorted().map { .init(name: $0, host: entries[$0]?.host) })
    }

    /// 지금 화면의 칸 가운데, 같은 호스트의 화면에서 받아 둔 값이 있는 것만.
    /// 호스트를 읽지 못한 화면에는 아무것도 넣지 않는다
    func values(for login: SiteLogin) -> [String: String] {
        var out: [String: String] = [:]
        guard !login.hostUnreadable else { return out }
        for field in login.fields where Self.names.contains(field.name) {
            if let entry = entries[field.name], entry.host == login.host { out[field.name] = entry.value }
        }
        return out
    }
}

/// 저장해 둔 것이 무엇인지 (값 없이)
struct SavedLoginInfo: Equatable, Sendable, Codable {
    struct Field: Equatable, Sendable, Codable {
        var name: String
        var host: String?
    }

    var fields: [Field]

    /// 지금 화면의 칸 가운데 저장해 둔 값을 넣을 수 있는 것. 호스트가 저장할 때와 다르면 넣지 않는다
    func names(for login: SiteLogin) -> Set<String> {
        var out: Set<String> = []
        guard !login.hostUnreadable else { return out }
        for field in login.fields where SavedLogin.names.contains(field.name) {
            let host = login.host
            if fields.contains(where: { $0.name == field.name && $0.host == host }) { out.insert(field.name) }
        }
        return out
    }

    /// "아이디·비밀번호" (연동 센터의 줄에 쓴다)
    var summary: String {
        let known = [("id", "아이디"), ("password", "비밀번호")]
        return known.filter { item in fields.contains { $0.name == item.0 } }.map(\.1).joined(separator: "·")
    }
}

enum LoginVaultRead: Equatable, Sendable {
    case value(SavedLogin)
    /// 얼굴 확인을 취소했다
    case cancelled
    /// 더 꺼낼 수 없다 (지워졌거나, 등록된 얼굴·지문이 바뀌었다)
    case gone
    /// 지금은 꺼내지 못했다 (확인 실패 등)
    case failed
}

protocol LoginVault: Sendable {
    /// 이 기기에서 쓸 수 있는지: Face ID나 Touch ID가 켜져 있을 때만
    var isAvailable: Bool { get }
    /// "Face ID" · "Touch ID"
    var unlockName: String { get }
    /// 저장해 둔 것이 있는지 (얼굴 확인 없이, 값 없이)
    func info(site: String) -> SavedLoginInfo?
    /// 저장해 둔 것이 있는 사이트
    func sites() -> [String]
    /// 전에 있던 것은 바꿔 넣는다
    func save(_ login: SavedLogin, site: String) throws
    /// 얼굴 확인 뒤에 꺼낸다
    func read(site: String, reason: String) async -> LoginVaultRead
    func remove(site: String)
}

struct LoginVaultError: Error, Equatable {
    /// 키체인이 돌려준 번호 (값은 들어 있지 않다)
    let status: Int32
}

enum LoginVaults {
    /// 앱이 쓰는 보관소. 화면 확인용 실행에서는 메모리에만 있는 가짜를 쓴다 (`-demoLoginVault` [`saved`]).
    /// 테스트에서는 없다 (시험이 기기의 키체인이나 얼굴 등록 상태에 기대지 않게. 시험은 가짜를 직접 넣는다)
    static let current: (any LoginVault)? = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-demoLoginVault") {
            let vault = MemoryLoginVault()
            if arguments.indices.contains(flag + 1), arguments[flag + 1] == "saved" {
                try? vault.save(SavedLogin(entries: ["id": .init(value: "minsu_demo"), "password": .init(value: "demo")]), site: "naver")
            }
            return vault
        }
        #endif
        return KeychainLoginVault()
    }()
}

/// 실제 보관소: 값은 얼굴 확인이 걸린 항목에, "무엇이 있는지"는 확인이 걸리지 않은 항목에 따로 둔다
struct KeychainLoginVault: LoginVault {
    static let service = "site-login"
    static let infoService = "site-login-info"

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var unlockName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    private static func base(_ service: String, site: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let site { query[kSecAttrAccount as String] = site }
        return query
    }

    func info(site: String) -> SavedLoginInfo? {
        var query = Self.base(Self.infoService, site: site)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SavedLoginInfo.self, from: data)
    }

    func sites() -> [String] {
        var query = Self.base(Self.infoService, site: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func save(_ login: SavedLogin, site: String) throws {
        let secret = try JSONEncoder().encode(login)
        let info = try JSONEncoder().encode(login.info)
        var failure: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &failure) else {
            failure?.release()
            throw LoginVaultError(status: errSecParam)
        }
        remove(site: site)
        var item = Self.base(Self.service, site: site)
        item[kSecAttrAccessControl as String] = access
        item[kSecValueData as String] = secret
        var status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LoginVaultError(status: status) }
        var note = Self.base(Self.infoService, site: site)
        note[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        note[kSecValueData as String] = info
        status = SecItemAdd(note as CFDictionary, nil)
        guard status == errSecSuccess else {
            // 값만 남고 "있다"는 표시가 없으면 지울 길이 화면에 보이지 않는다. 함께 지운다
            remove(site: site)
            throw LoginVaultError(status: status)
        }
    }

    func read(site: String, reason: String) async -> LoginVaultRead {
        // 얼굴 확인이 끝날 때까지 멈춰 있는 호출이라 화면을 그리는 흐름 밖에서 한다
        let result: LoginVaultRead = await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            // 기기 암호로 대신 여는 단추는 보이지 않게 한다 (이 항목은 얼굴·지문으로만 열린다)
            context.localizedFallbackTitle = ""
            var query = Self.base(Self.service, site: site)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context
            var out: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &out) {
            case errSecSuccess:
                guard let data = out as? Data, let login = try? JSONDecoder().decode(SavedLogin.self, from: data) else { return .gone }
                return .value(login)
            case errSecUserCanceled:
                return .cancelled
            case errSecItemNotFound:
                return .gone
            default:
                return .failed
            }
        }.value
        if result == .gone { remove(site: site) }
        return result
    }

    func remove(site: String) {
        SecItemDelete(Self.base(Self.service, site: site) as CFDictionary)
        SecItemDelete(Self.base(Self.infoService, site: site) as CFDictionary)
    }
}

#if DEBUG
/// 메모리에만 있는 가짜 보관소 (테스트와 화면 확인용). 얼굴 확인은 정해 둔 답으로 대신한다
final class MemoryLoginVault: LoginVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: SavedLogin] = [:]
    private var _isAvailable: Bool
    private var _answer: LoginVaultRead?
    private var _reads = 0
    private var _saveFails = false

    init(isAvailable: Bool = true) {
        _isAvailable = isAvailable
    }

    var isAvailable: Bool {
        get { lock.withLock { _isAvailable } }
        set { lock.withLock { _isAvailable = newValue } }
    }

    /// 얼굴 확인의 답을 정해 둔다 (nil이면 저장된 값을 그대로 준다)
    var answer: LoginVaultRead? {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    /// 얼굴 확인을 몇 번 물었는지
    var reads: Int { lock.withLock { _reads } }

    var saveFails: Bool {
        get { lock.withLock { _saveFails } }
        set { lock.withLock { _saveFails = newValue } }
    }

    let unlockName = "Face ID"

    func stored(site: String) -> SavedLogin? { lock.withLock { items[site] } }

    func info(site: String) -> SavedLoginInfo? { lock.withLock { items[site]?.info } }

    func sites() -> [String] { lock.withLock { items.keys.sorted() } }

    func save(_ login: SavedLogin, site: String) throws {
        try lock.withLock {
            if _saveFails { throw LoginVaultError(status: errSecAuthFailed) }
            items[site] = login
        }
    }

    func read(site: String, reason: String) async -> LoginVaultRead {
        lock.withLock {
            _reads += 1
            if let _answer {
                if _answer == .gone { items[site] = nil }
                return _answer
            }
            guard let login = items[site] else { return .gone }
            return .value(login)
        }
    }

    func remove(site: String) {
        lock.withLock { items[site] = nil }
    }
}
#endif
