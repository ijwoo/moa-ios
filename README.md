# 모아 (Moa) — 내 맥에서 도는 개인 비서의 아이폰 앱

<p align="center"><img src="docs/media/moa-demo.gif" width="300" alt="명령 → 사람 확인을 폰으로 넘겨 직접 풀기 → 결과 카드"></p>

> 30초 데모: 명령을 보내면 맥의 브라우저가 대신 일하다가, 사람 확인(캡차) 화면을 만나면 멈추고 그 화면을 폰으로 넘깁니다. 사람이 폰에서 직접 풀고 "다 했어요"를 누르면 이어서 하고, 결과를 카드로 돌려줍니다. (영상의 가게·값·사이트는 모두 지어낸 것입니다)

**English summary** — Moa is an iOS 26 SwiftUI app that drives a personal agent running on your own Mac (over Tailscale). The agent browses and acts for you; anything irreversible needs your approval on the phone (approved drafts are pinned by hash), and when it hits a human check it hands the live screen to your phone so *you* solve it. It also records meetings with on-device transcription and an on-device-first flow: audio never leaves the phone, only the transcript text goes to a small relay server that summarizes it into decisions and action items.swers questions about them with citations.

## 무엇을 하나요

- **맥에 일 맡기기**: 폰에서 말로 시키면 집에 있는 맥의 에이전트가 브라우저로 대신 찾고, 결과를 답변 카드로 돌려줍니다.
- **되돌릴 수 없는 일은 폰에서 승인**: 메일 보내기, 사이트의 버튼 누르기 같은 일은 항상 승인 카드를 거칩니다. 승인한 초안은 해시로 고정돼서, 승인한 것과 다르면 맥이 실행하지 않습니다.
- **사람 확인은 사람이**: 에이전트는 캡차를 풀지 않습니다. 그 화면을 폰으로 넘겨 받아 직접 누르고 씁니다(손 넘기기).
- **작업 중에도 대화**: 작업이 도는 동안 일상 대화를 하고, "이렇게 바꿔 줘"로 끼어들 수 있습니다. 서로 다른 일은 함께 돌아갑니다.
- **사이트 로그인**: 로그인 값은 맥에 남기지 않고, 원하면 이 아이폰의 키체인에 두었다가 Face ID로 꺼내 씁니다.
- **기억**: 맥이 대화에서 정리한 요약을 보고, 고치고, 되돌리고, 지난 대화를 찾을 수 있습니다.
- **회의 기록**: 녹음을 기기 안에서 받아쓰고(음성은 서버로 보내지 않음), 결정 사항·할 일로 요약해 미리알림에 넣습니다. 지난 회의에 질문하면 근거가 된 발언으로 바로 갑니다.
- **에이전트에게 전화**: 통화하듯 말로 주고받습니다(듣기는 기기 안 음성 인식).

| 작업 중 끼어들기 | 로그인 중 사람 확인 | 기억 |
|---|---|---|
| <img src="docs/media/steer.png" width="240"> | <img src="docs/media/login-handover.png" width="240"> | <img src="docs/media/memory.png" width="240"> |

## 구조

```
아이폰 (이 저장소)  ──Tailscale──▶  맥 에이전트 (moa-agent)  ──▶  브라우저 · 작업실 · 모델
        │
        └──HTTPS──▶  중계 서버 (proxy/, 회의 요약·질문용, API 키는 서버에만)
```

- 맥 에이전트: [ijwoo/moa-agent](https://github.com/ijwoo/moa-agent) ([설치](https://github.com/ijwoo/moa-agent#설치-맥)) — 맥 기능은 그쪽이 알려 주는 기능(`/v1/health`의 features)이 있을 때만 켜집니다.
- 설계 문서: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 초기 설계 기준이라 지금 구현과 다른 부분이 있을 수 있습니다. 최신 내용은 결정 기록을 따르세요.
- 결정 기록: [docs/DECISIONS.md](docs/DECISIONS.md) — 무엇을 왜 그렇게 정했는지 150개 남짓의 기록

## 맥 없이 둘러보기

Debug 빌드는 가짜 맥(지어낸 데이터)으로 화면을 볼 수 있습니다. Xcode의 Scheme › Run › Arguments에 넣으세요.

| 보고 싶은 것 | 실행 인자 |
|---|---|
| 데모 영상과 같은 흐름 | `-demo -demoAgent -demoHandover -demoNewChat -demoReel "가상몰에서 무선 이어폰 최저가 찾아줘"` |
| 작업 중 끼어들기 | `-demo -demoAgent -demoNewChat -demoReport -demoSteer -demoAsk "이 자료로 한 장짜리 보고서 만들어 줘" -demoSteerSay "그래프는 막대로 바꿔 줘"` |
| 기억 화면 | `-demo -demoAgent -demoTab profile -demoProfileScreen memory -demoMemory` |

## 빌드

필요한 것: Xcode 26(iOS 26 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig   # 값은 비워 둬도 빌드된다
xcodegen generate
open MeetingSummary.xcodeproj
```

- `project.yml`의 `DEVELOPMENT_TEAM`에 내 팀 ID를 넣고, 번들 ID를 내 것으로 바꿉니다. `bundleIdPrefix`(`com.example`)만 바꾸면 안 됩니다. `project.yml`에 `com.example.meetingsummary`(앱·알림 확장·위젯·테스트의 `PRODUCT_BUNDLE_IDENTIFIER`와 URL 이름)가 그대로 박혀 있으니 함께 바꿔야 합니다.
- `Config/Secrets.xcconfig`의 값:
  - `PROXY_HOST`, `PROXY_APP_TOKEN`: 중계 서버 주소와 토큰. 예시 주소(`meeting-api.example.com`)를 그대로 두면 회의 요약 글이 그 주소로 나가니 반드시 내 서버 주소로 바꾸세요.
  - `AGENT_HOST`, `AGENT_APP_TOKEN`: 맥 에이전트(moa-agent)의 주소와 앱 토큰. 맥 기능을 쓰려면 필요하고, 비워 두면 회의 기록·요약만 됩니다.
- 날씨 카드(WeatherKit)와 알림(Push Notifications)은 앱 ID에 그 기능을 켜야 서명됩니다. 쓰지 않으면 `project.yml`의 `entitlements` 항목에서 빼세요.
- 테스트: `xcodebuild test -project MeetingSummary.xcodeproj -scheme MeetingSummary -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`

### 중계 서버 (회의 요약·질문)

```sh
cd proxy
cp .env.example .env   # ANTHROPIC_API_KEY, APP_TOKEN 등을 채운다
npm install && npm start
```

- Node 22 이상이 필요합니다.
- `SUMMARY_MODEL`: 요약 모델. 기본은 Opus(`claude-opus-5-5`)라 비용이 큽니다. 줄이려면 `claude-sonnet-5-5`나 `claude-haiku-5-5`로 바꾸세요.
- `PORT`(기본 3100), `HOST`(기본 127.0.0.1): 서버가 듣는 포트와 주소. 밖에서 받으려면 HTTPS를 앞단에 두세요.

앱의 `Config/Secrets.xcconfig`에 서버 주소(`PROXY_HOST`)와 같은 `APP_TOKEN`(`PROXY_APP_TOKEN`)을 넣습니다.

## 지키는 것

- 실제 회의 내용·이름·로그인 값은 저장소와 로그에 남기지 않습니다. 화면과 데모는 지어낸 데이터로 만듭니다.
- 녹음과 받아쓰기는 기기 안에서만 합니다. 서버로 가는 것은 요약에 필요한 글뿐입니다.
- 맥이 보낸 화면(손 넘기기, 작업 캡처)은 메모리에서만 그리고 저장하지 않습니다.

## 라이선스

[MIT](LICENSE)
