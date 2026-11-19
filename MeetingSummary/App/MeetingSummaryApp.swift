import SwiftData
import SwiftUI

@main
struct MeetingSummaryApp: App {
    /// 알림을 받는 자리 (D67)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        do {
            // 최초 실행 시 Application Support 폴더가 없으면 SwiftData가 오류 로그를 남기므로 먼저 만든다.
            let support = URL.applicationSupportDirectory
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: Meeting.self, Summary.self, ActionItem.self, Utterance.self, Bookmark.self, Conversation.self, ChatRecord.self,
                configurations: ModelConfiguration(url: support.appending(path: "MeetingSummary.store"))
            )
        } catch {
            fatalError("저장소를 열 수 없습니다: \(error)")
        }
        MeetingSummarizer.recoverInterrupted(in: container.mainContext)
        #if DEBUG
        DemoData.seed(into: container.mainContext)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .applyingAppSettings()
        }
        .modelContainer(container)
    }
}
