import Foundation
import UIKit

// 쇼핑 "스스로 찾아 오기" (D75): 맥의 작업이 시킨 일을 앱 안의 쇼핑 화면에서 한다.
//
// 할 수 있는 일은 둘뿐이다.
// - 검색: 앱이 만든 검색 주소를 열고 목록을 읽는다
// - 열기: 방금 읽은 목록에서 맥이 고른 "몇 번째" 상품의 화면을 열고 읽는다
//
// 지키는 것:
// - 주소를 열기만 한다. 아무것도 누르지 않고, 화면을 고치지 않는다 (읽는 스크립트는 D74의 것 그대로다)
// - 상품은 목록의 링크가 **상품 화면으로 바로 가는 주소**일 때만 연다. 거쳐 가는 주소나 광고 주소는 열지 않는다
//   (앱이 광고를 대신 누르는 일이 없게. 그런 상품은 "열지 않았다"고 돌려준다)
// - 한 번에 상품 셋까지, 한 작업에서 상품 화면 여섯·검색 둘까지. 화면을 여는 사이에는 틈을 둔다
// - 브라우저를 꾸미지 않는다. 사이트가 접속을 제한하면(418·429·403) 그 자리에서 멈추고, 그 작업에서는 더 열지 않는다
// - 로그인·확인 화면처럼 엉뚱한 화면으로 넘어가면 돌아가지 않고 멈춘다. 검색에서도, 상품을 열다가도 그렇다:
//   상품을 열었는데 로그인 화면이 나오면 남은 상품을 열지 않는다 (같은 화면을 거듭 만나지 않게).
//   로그인은 내가 그 화면에서 직접 한다 (앱은 대신 하지 않고, 로그인 칸을 읽지도 않는다)
// - 내가 "멈추기"를 누르면 바로 멈춘다. 앱이 뒤로 가 있는 동안에는 새 화면을 열지 않는다
extension ShopBrowser {
    /// 맥의 작업이 이 화면을 옮기는 중일 때: 어느 작업이고, 지금 무엇을 하는지
    struct Drive: Equatable, Sendable {
        let taskID: String
        var text: String
    }

    /// 시킨 일을 할 때의 빠르기
    struct Pace: Sendable {
        /// 화면을 다 받은 뒤, 화면이 스스로 채워질 틈
        var settle: Duration = .milliseconds(900)
        /// 상품 화면 하나를 열기 전에 두는 틈
        var gap: Duration = .seconds(2)
        /// 화면 하나를 기다리는 한도
        var loadLimit: Duration = .seconds(20)
        /// 한 화면을 읽어 보는 횟수와 그 사이의 틈 (사이트에 다시 묻지 않는다. 이미 받은 화면을 다시 읽을 뿐이다)
        var readTries = 3
        var readGap: Duration = .milliseconds(800)
        /// 앱이 앞에 있을 때만 새 화면을 연다
        var waitsForActive = true

        static let app = Pace()
        /// 가상 쇼핑몰과 테스트 (어디에도 접속하지 않으니 틈을 길게 둘 까닭이 없다)
        static let quick = Pace(
            settle: .milliseconds(150), gap: .milliseconds(80), loadLimit: .seconds(10), readGap: .milliseconds(150), waitsForActive: false
        )
    }

    /// 시킨 일을 하며 기억해 두는 것. 이 기기의 메모리에만 있다 (저장하지 않고, 맥으로 보내지 않는다)
    struct DriveMemory {
        /// 마지막으로 읽은 목록의 상품마다, 그 상품으로 가는 링크의 주소들
        var listLinks: [[URL]] = []
        /// 링크를 하나도 찾지 못한 상품이면 그 까닭 (D77. 읽는 스크립트가 적은 낱말)
        var listGaps: [String?] = []
        var hasList = false
        /// 작업마다 한 검색 수와, 열기로 잡아 둔 상품 화면 수
        var searches: [String: Int] = [:]
        var opens: [String: Int] = [:]
        /// 일(작업/번호)마다 열어도 되는 상품 수 (같은 일을 다시 해도 두 번 세지 않는다)
        var allowance: [String: Int] = [:]
        var counted: Set<String> = []
        /// 방금 끝낸 일과 그 결과 (결과를 보내다 끊겨 같은 일이 다시 오면 화면을 다시 열지 않고 이것을 준다)
        var finished: (key: String, result: BrowseResult)?
        /// 더 하지 않는 작업 (내가 멈췄거나, 사이트가 막았거나, 엉뚱한 화면으로 넘어갔다)
        var closed: Set<String> = []
        var isRunning = false
        /// 시킨 일을 하며 연 주소 (테스트 확인용)
        var visited: [URL] = []
    }

    /// 사이트가 접속을 제한했다고 보는 응답 번호
    static let limitStatuses: Set<Int> = [403, 418, 429]

    private enum Arrival {
        case arrived
        case limited(Int)
        /// 앱 안에서 열지 않는 주소로 넘어가려 했다
        case away
        /// 열지 못했다: 그 까닭과, 응답 번호 때문이면 그 번호
        case failed(BrowseResult.Failure, status: Int?)
        case stopped
    }

    // MARK: - 시킨 일 하기

    /// 맥의 작업이 시킨 일 하나를 한다.
    /// 멈췄으면(내가 "멈추기"를 눌렀거나 화면이 사라졌으면) nil을 준다: 그때는 결과를 보내지 않는다
    func run(_ command: AgentBrowse, task: String) async -> BrowseResult? {
        let key = "\(task)/\(command.id)"
        if let done = memory.finished, done.key == key { return done.result }
        while memory.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        guard !Task.isCancelled else { return nil }
        // 이 작업에서 이미 멈췄으면 더 하지 않는다
        guard !memory.closed.contains(task) else { return BrowseResult(id: command.id, outcome: .refused, reason: "stopped") }
        memory.isRunning = true
        defer { memory.isRunning = false }
        isPresented = true
        let result: BrowseResult?
        switch command.kind {
        case .search: result = await runSearch(command, task: task, key: key)
        case .open: result = await runOpen(command, task: task, key: key)
        }
        if let result {
            memory.finished = (key, result)
            if result.outcome == .limited || result.outcome == .blocked { memory.closed.insert(task) }
            // 로그인 화면에서 멈췄으면 화면을 바로 내게 넘긴다: 거기서 직접 로그인할 수 있게
            // (에이전트가 찾는 동안에는 화면을 누를 수 없다. 2026-11-15 실제 기기에서 로그인 화면을 누르지 못했다)
            if result.outcome == .blocked, notice == .login { drive = nil }
        }
        return result
    }

    /// 내가 "멈추기"를 눌렀다: 받던 화면을 멈추고, 이 작업에서는 더 열지 않는다
    func stopDrive() {
        guard let task = drive?.taskID else { return }
        memory.closed.insert(task)
        stop()
        drive = nil
    }

    private func runSearch(_ command: AgentBrowse, task: String, key: String) async -> BrowseResult? {
        guard let query = command.query else { return BrowseResult(id: command.id, outcome: .refused, reason: "bad_command") }
        if !memory.counted.contains(key) {
            guard memory.searches[task, default: 0] < AgentBrowse.taskSearchLimit else {
                return BrowseResult(id: command.id, outcome: .refused, reason: "cap")
            }
            memory.counted.insert(key)
            memory.searches[task, default: 0] += 1
        }
        drive = Drive(taskID: task, text: "‘\(query)’ 검색 결과를 열고 있어요")
        guard await ready(task) else { return nil }
        memory.hasList = false
        memory.listLinks = []
        memory.listGaps = []
        mainStatus = nil
        let before = commits
        if search(query) {
            if let url = site.searchURL(for: query) { memory.visited.append(url) }
            switch await arrive(task, after: before) {
            case .stopped: return nil
            case .limited(let status): return BrowseResult(id: command.id, outcome: .limited, status: status)
            case .away: return BrowseResult(id: command.id, outcome: .blocked)
            case .failed(let failure, let status):
                // 왜 열지 못했는지 낱말로 알린다. 다시 시도하지는 않는다 (사이트가 막은 것이면 다시 여는 일이 돌아가는 짓이 된다)
                return BrowseResult(id: command.id, outcome: .failed, status: status, reason: failure.rawValue)
            case .arrived: break
            }
        }
        // 검색 결과가 아닌 화면(로그인·확인 화면 같은 것)이면 돌아가지 않고 멈춘다
        guard page?.kind == .list else {
            let atLogin = site.isLogin(address)
            if atLogin { notice = .login }
            return BrowseResult(id: command.id, outcome: .blocked, reason: atLogin ? "login" : nil)
        }
        drive?.text = "검색 결과를 읽고 있어요"
        for attempt in 0..<max(1, pace.readTries) {
            if attempt > 0 { guard await pause(pace.readGap, task) else { return nil } }
            let read = await readWithLinks()
            if case .view(var view) = read.result, view.kind == .list {
                // 줄마다 이 기기에서 바로 열 수 있는지 적어 보낸다: 맥이 열 수 없는 줄을 고르지 않게 (주소는 보내지 않는다)
                view.fields.items = (view.fields.items ?? []).enumerated().map { index, item in
                    var item = item
                    item.canOpen = index < read.links.count && productLink(in: read.links[index]) != nil
                    return item
                }
                view = view.fitted()
                let count = view.fields.items?.count ?? 0
                memory.listLinks = Array(read.links.prefix(count))
                memory.listGaps = Array(read.gaps.prefix(count))
                memory.hasList = true
                drive?.text = "살펴볼 상품을 고르고 있어요"
                return BrowseResult(id: command.id, outcome: .ok, views: [.init(item: nil, view: view)])
            }
        }
        return BrowseResult(id: command.id, outcome: .nothing)
    }

    /// 그 상품의 링크 가운데 상품 화면으로 바로 가는 주소 (거쳐 가는 주소·광고 주소는 열지 않는다)
    private func productLink(in links: [URL]) -> URL? {
        links.first { site.page(for: $0)?.kind == .product }
    }

    /// 열지 않는 까닭: 목록에 없는 차례, 링크가 없음, https 주소가 없음, 모두 다른 호스트, 여는 호스트지만 상품 화면이 아님
    private func skipReason(for index: Int) -> BrowseResult.Skip.Reason {
        guard index < memory.listLinks.count else { return .noLink }
        let links = memory.listLinks[index]
        if links.isEmpty {
            switch index < memory.listGaps.count ? memory.listGaps[index] : nil {
            case "no_anchor": return .noAnchor
            case "no_href": return .noHref
            default: return .noLink
            }
        }
        return links.contains { site.allows($0) } ? .outside : .otherMall
    }

    private func runOpen(_ command: AgentBrowse, task: String, key: String) async -> BrowseResult? {
        guard let wanted = command.items, !wanted.isEmpty else { return BrowseResult(id: command.id, outcome: .refused, reason: "bad_command") }
        guard memory.hasList else { return BrowseResult(id: command.id, outcome: .refused, reason: "no_list") }
        let allowed: Int
        if let kept = memory.allowance[key] {
            allowed = kept
        } else {
            allowed = max(0, min(AgentBrowse.openLimit, AgentBrowse.taskOpenLimit - memory.opens[task, default: 0]))
            memory.allowance[key] = allowed
            memory.opens[task, default: 0] += allowed
        }
        guard allowed > 0 else { return BrowseResult(id: command.id, outcome: .refused, reason: "cap") }

        var views: [BrowseResult.Entry] = []
        var skipped: [BrowseResult.Skip] = []
        let total = min(allowed, wanted.count)
        var opened = 0
        for index in wanted {
            guard opened < allowed else {
                skipped.append(.init(item: index, reason: .limit))
                continue
            }
            // 상품 화면으로 바로 가는 주소만 연다 (거쳐 가는 주소·광고 주소는 열지 않는다)
            guard let link = productLink(in: index < memory.listLinks.count ? memory.listLinks[index] : []) else {
                skipped.append(.init(item: index, reason: skipReason(for: index)))
                continue
            }
            opened += 1
            drive = Drive(taskID: task, text: "상품 화면을 열고 있어요 (\(opened)/\(total))")
            guard await pause(pace.gap, task), await ready(task) else { return nil }
            mainStatus = nil
            let before = commits
            memory.visited.append(link)
            visit(link)
            switch await arrive(task, after: before) {
            case .stopped:
                return nil
            case .limited(let status):
                // 사이트가 막았다: 여기서 멈춘다 (남은 상품은 열지 않는다)
                return BrowseResult(id: command.id, outcome: .limited, status: status, views: views, skipped: skipped)
            case .away:
                skipped.append(.init(item: index, reason: .outside))
                continue
            case .failed:
                // 상품 하나를 열지 못한 것은 그 상품만 건너뛴다 (까닭은 검색에서만 알린다)
                skipped.append(.init(item: index, reason: .failed))
                continue
            case .arrived:
                break
            }
            guard page?.kind == .product else {
                skipped.append(.init(item: index, reason: .notProduct))
                // 로그인·확인 화면으로 넘어갔으면 여기서 멈춘다 (남은 상품은 열지 않는다)
                if let reason = strayReason() {
                    return BrowseResult(id: command.id, outcome: .blocked, reason: reason, views: views, skipped: skipped)
                }
                continue
            }
            drive?.text = "상품 화면을 읽고 있어요 (\(opened)/\(total))"
            var best: ShopView?
            for attempt in 0..<max(1, pace.readTries) {
                if attempt > 0 { guard await pause(pace.readGap, task) else { return nil } }
                if case .view(let view) = await readWithLinks().result, view.kind == .product {
                    best = view
                    // 이름·가격·배송비를 다 읽었으면 그만 읽는다
                    if view.missing.isEmpty { break }
                }
            }
            if let best {
                views.append(.init(item: index, view: best))
            } else if let reason = strayReason() {
                // 읽는 사이에 로그인·확인 화면으로 넘어갔다: 여기서 멈춘다
                skipped.append(.init(item: index, reason: .notProduct))
                return BrowseResult(id: command.id, outcome: .blocked, reason: reason, views: views, skipped: skipped)
            } else {
                skipped.append(.init(item: index, reason: .unread))
            }
        }
        drive?.text = "읽은 것을 정리하고 있어요"
        return BrowseResult(id: command.id, outcome: views.isEmpty ? .nothing : .ok, views: views, skipped: skipped)
    }

    /// 상품을 열었는데 상품을 두는 곳이 아닌 화면에 와 있으면 그 까닭을 낱말로 준다 (주소는 보내지 않는다).
    /// 로그인 화면이면 `login`, 그 밖의 곳이면 `moved`. 상품을 두는 호스트 안이면 nil이다 (없는 상품 같은 것: 그 상품만 건너뛴다)
    private func strayReason() -> String? {
        if site.isLogin(address) {
            notice = .login
            return "login"
        }
        guard let host = address?.host()?.lowercased() else { return "moved" }
        return site.productHosts.contains(host) ? nil : "moved"
    }

    // MARK: - 기다리기

    private func alive(_ task: String) -> Bool {
        !Task.isCancelled && !memory.closed.contains(task)
    }

    /// 잠깐 기다린다. 그 사이 멈췄으면 false
    private func pause(_ duration: Duration, _ task: String) async -> Bool {
        try? await Task.sleep(for: duration)
        return alive(task)
    }

    /// 앱이 앞에 올 때까지 기다린다 (뒤에 가 있는 동안에는 새 화면을 열지 않는다)
    private func ready(_ task: String) async -> Bool {
        while pace.waitsForActive, UIApplication.shared.applicationState != .active {
            guard await pause(.milliseconds(300), task) else { return false }
        }
        return alive(task)
    }

    /// 방금 연 화면이 다 올 때까지 기다린다 (`before`: 열기 전의 `commits`)
    private func arrive(_ task: String, after before: Int) async -> Arrival {
        let clock = ContinuousClock()
        let started = clock.now
        while commits == before || isLoading || address == nil {
            if let status = mainStatus, Self.limitStatuses.contains(status) { return .limited(status) }
            if case .failed = notice { return .failed(loadFailure ?? .loadError, status: nil) }
            if case .blocked = notice { return .away }
            if clock.now - started > pace.loadLimit {
                stop()
                return .failed(.timeout, status: nil)
            }
            guard await pause(.milliseconds(100), task) else { return .stopped }
        }
        // 화면이 스스로 채워질 틈
        guard await pause(pace.settle, task) else { return .stopped }
        if let status = mainStatus {
            if Self.limitStatuses.contains(status) { return .limited(status) }
            if status >= 400 { return .failed(.httpStatus, status: status) }
        }
        if case .limited(let status) = notice { return .limited(status) }
        if case .failed = notice { return .failed(loadFailure ?? .loadError, status: nil) }
        return .arrived
    }
}
