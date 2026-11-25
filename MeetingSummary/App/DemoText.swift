import Foundation

/// English demo mode (debug launch argument `-demoEnglish`): swaps only the strings visible in the README demos
/// (demo reel, live steering, memory screen) for English. The app itself is Korean; release builds always return the original text.
/// 영문 데모 (개발용 `-demoEnglish`): README의 데모(데모 릴·끼어들기·기억 화면)에 보이는 글만 영어로. 배포 빌드에서는 늘 원래 글
enum DemoText {
    #if DEBUG
    static let english = ProcessInfo.processInfo.arguments.contains("-demoEnglish")
    #else
    static let english = false
    #endif

    /// 영문 데모일 때만 표의 글로 바꾼다. 표에 없으면 원래 글
    static func t(_ text: String) -> String {
        #if DEBUG
        guard english else { return text }
        return table[text] ?? text
        #else
        return text
        #endif
    }

    #if DEBUG
    private static let table: [String: String] = [
        // 대화 화면
        "모아": "Moa",
        "작업 중": "Working",
        "답변 필요": "Needs you",
        "물어보거나 부탁하기": "Ask or delegate anything",
        "질문에 답하기": "Answer the question",
        "좋은 아침이에요": "Good morning",
        "안녕하세요": "Hello",
        "좋은 저녁이에요": "Good evening",
        "늦게까지 수고 많아요": "Working late?",
        "궁금한 것도, 맡길 일도 편하게 말해 보세요.": "Ask anything, or hand off a task.",
        "오늘 받은 메일 요약해줘": "Summarize today's email",
        "오늘 날씨 어때?": "What's the weather today?",
        "모아야 뭐 할 수 있어?": "What can you do, Moa?",
        "지난 회의 결정 사항 정리해줘": "Recap last meeting's decisions",
        // 작업 카드
        "멈추기": "Stop",
        "직접 해 주셔야 해요": "Your turn",
        "확인할 것이 있어요": "Quick check",
        "화면 열기": "Open screen",
        // 손 넘기기 화면
        "닫기": "Close",
        "사이트 화면": "Site screen",
        "직접 해 주세요": "Your turn",
        "실시간": "Live",
        "연결 중": "Connecting",
        "누르기·스크롤": "Tap · Scroll",
        "끌기": "Drag",
        // 가짜 맥 (모두 지어낸 것)
        "네, 가상몰에서 찾아볼게요.": "On it — checking Demo Shop now.",
        "가상몰에서 찾기": "Searching Demo Shop",
        "작업을 시작했어요": "Started the task",
        "mail.test를 열었어요": "Opened shop.test",
        "화면 내용을 읽었어요": "Read the page",
        "페이지를 열고 있어요": "Opening the page",
        "화면에서 항목을 고르고 있어요": "Looking at the page",
        "작업을 마쳤어요": "Finished",
        "다 했어요": "Done",
        "그만하기": "Cancel",
        "사람 확인 퍼즐": "Human check",
        "사람인지 확인하는 화면이 나왔어요. 브라우저를 열어 직접 풀어 주세요. 다 하면 \"다 했어요\"를 눌러 주세요.":
            "The store wants a human check. Open the screen and solve it yourself — tap “Done” when you're finished.",
        "답을 받아 이어서 진행해요": "Got it — continuing",
        "가상몰": "Demo Shop",
        "사람인지 확인해 주세요": "Confirm you're human",
        "자전거가 있는 칸을 모두 누르세요": "Tap every square with a bicycle",
        "확인 문자": "Verify",
        "가장 싼 곳은 달빛 전자, 39,800원이에요.": "Cheapest: Moonlight Electronics at $39.80.",
        "가상몰에서 무선 이어폰 판매처 3곳의 값을 비교했어요": "Compared wireless earbuds across 3 sellers on Demo Shop.",
        "무엇부터 시작할까요?": "Where should we start?",
        "무엇이 궁금하세요?": "What would you like to know?",
        "회의 내용을 묻거나 메일 초안 같은 일을 맡겨 보세요. 바꾸는 일은 승인한 뒤에만 해요.":
            "Ask about your meetings or hand off tasks like email drafts. Anything that changes things waits for your approval.",
        "회의 내용 물어보기": "Ask about your meetings",
        // 끼어들기·보고서 (모두 지어낸 것)
        "보고서 만들기": "Building the report",
        "네, 작업실에서 한 장짜리 보고서로 만들게요.": "On it — making a one-page report in the workroom.",
        "자료를 읽었어요": "Read the source data",
        "쪽 구성을 정했어요": "Planned the layout",
        "숫자를 표로 정리했어요": "Put the numbers in a table",
        "그래프를 그렸어요": "Drew the chart",
        "요약 문단을 썼어요": "Wrote the summary",
        "제목과 머리말을 다듬었어요": "Polished the title and intro",
        "쪽 나눔을 확인했어요": "Checked page breaks",
        "그래프를 다시 그렸어요": "Redrew the chart",
        "글자 크기를 맞췄어요": "Adjusted font sizes",
        "PDF로 엮었어요": "Exported to PDF",
        "결과를 확인했어요": "Reviewed the result",
        "작업실에서 보고서를 만들고 있어요": "Building the report in the workroom",
        "덧붙인 말을 받았어요 — 지금 단계가 끝나면 반영해요": "Got your note — applying it after this step",
        "덧붙인 말을 반영하고 있어요": "Applying your note",
        "지금 하는 작업에 전했어요. 지금 단계가 끝나면 반영해요.": "Passed to the running task — it'll apply after the current step.",
        "한 장짜리 보고서를 만들었어요. 그래프는 막대로 바꿨어요.": "Made a one-page report. Switched the chart to bars.",
        "한 장짜리 보고서를 만들었어요.": "Made a one-page report.",
        "지난 회의에서 정한 결정 사항이 뭐였지?": "What did we decide in the last meeting?",
        "아직 해결 안 된 질문 정리해줘": "List the open questions",
        "담당자가 정해진 할 일만 알려줘": "Show tasks that have an owner",
        "지난 회의 할 일로 팀 공유 메일 초안 써줘": "Draft a team email from last meeting's to-dos",
        "지난 회의에서 찾아 근거와 함께 답해 드려요.": "I'll answer from your meetings, with sources.",
        "브라우저 열기": "Open browser",
        "맥의 브라우저": "Mac browser",
        "진행 중": "Running",
        "완료": "Done",
        // 기억 화면
        "기억": "Memory",
        "직접 고치기": "Edit",
        "한 단계 되돌리기": "Undo last change",
        "지난 대화에서 찾기": "Search past chats",
        "지난 대화 찾기": "Search past chats",
        "맥이 보관한 지난 대화에서 찾아요. 대화에서 \"지난주에 얘기한 … 뭐였지?\"라고 물어도 맥이 찾아 답해요.":
            "Searches the chats your Mac keeps. You can also just ask, “What did we say last week about …?”",
        "기억 모두 지우기": "Erase all memory",
        "요약과 지난 대화를 맥에서 모두 지워요. 되돌릴 수 없어요.": "Erases the summary and past chats from your Mac. This can't be undone.",
        "진행 중인 작업에 전했어요": "Sent to the running task",
        "앞 승인을 거두고 새로 시작해요": "Withdrew the pending approval and restarted",
        "반영함": "Applied",
        "반영 전": "Pending",
    ]
    #endif
}
