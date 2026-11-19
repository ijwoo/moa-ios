import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createApp, Limiter } from "../src/server.js";
import { createClient } from "../src/summarize.js";
import { buildMessages, validateAskInput } from "../src/ask.js";

let lastRequest = null;
let nextText = null;
const upstream = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    lastRequest = { headers: req.headers, body: JSON.parse(body) };
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      id: "msg", type: "message", role: "assistant", model: "claude-haiku-5-5",
      content: [{ type: "text", text: nextText }], stop_reason: "end_turn", stop_sequence: null,
      usage: { input_tokens: 900, output_tokens: 120 },
    }));
  });
});

const TOKEN = "t";
let baseURL;
let app;

const MEETINGS = [
  {
    ref: "m1", title: "주간 회의", date: "2026-11-10 16:12", summary: "출시 일정 점검",
    utterances: [
      { ref: "m1-u1", start: 3, text: "출시일은 12월 3일로 확정했습니다." },
      { ref: "m1-u2", start: 16, text: "디자인 최종본은 김지원 님이 금요일까지 전달합니다." },
    ],
  },
];
const BODY = { question: "디자인 최종본은 누가 언제까지 줘?", meetings: MEETINGS, other_meetings: [{ ref: "m2", title: "면담", date: "2026-11-01", topic: "평가" }] };

before(async () => {
  await new Promise((r) => upstream.listen(0, "127.0.0.1", r));
  const client = createClient({ apiKey: "sk-test", baseURL: `http://127.0.0.1:${upstream.address().port}`, maxRetries: 0 });
  app = createApp({ client, appToken: TOKEN, limiter: new Limiter(), model: "claude-haiku-5-5" });
  await new Promise((r) => app.listen(0, "127.0.0.1", r));
  baseURL = `http://127.0.0.1:${app.address().port}`;
});
after(() => { app.close(); upstream.close(); });
beforeEach(() => {
  lastRequest = null;
  nextText = JSON.stringify({ answer: "김지원 님이 금요일까지 전달합니다.", found: true, citations: ["m1-u2"] });
});

const post = (body) => fetch(`${baseURL}/v1/ask`, {
  method: "POST", headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" }, body: JSON.stringify(body),
});

test("질문: 답변과 인용 번호를 돌려준다", async () => {
  const res = await post(BODY);
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).answer, { answer: "김지원 님이 금요일까지 전달합니다.", found: true, citations: ["m1-u2"] });
});

test("요청 형식: 자료에 말풍선 번호·시각, 다른 회의 목록, JSON 스키마", async () => {
  await post(BODY);
  const { body } = lastRequest;
  assert.equal(body.model, "claude-haiku-5-5");
  assert.equal(body.output_config.format.type, "json_schema");
  assert.equal(body.fallbacks, undefined); // Haiku는 미지원
  const content = body.messages[0].content;
  assert.match(content, /\[m1-u2 · 00:16\] 디자인 최종본은/);
  assert.match(content, /<다른 회의 목록>\n- 면담 \(2026-11-01\): 평가/);
  assert.match(content, /질문: 디자인 최종본은 누가/);
  assert.match(body.system, /자료에 없는 번호를 만들지 마세요/);
  assert.match(body.system, /줄마다 "• "로 시작/);
});

test("자료에 없는 인용 번호는 버린다 (지어낸 인용 방지)", async () => {
  nextText = JSON.stringify({ answer: "…", found: true, citations: ["m1-u2", "m9-u1", "m1-u2", 3] });
  const res = await post(BODY);
  assert.deepEqual((await res.json()).answer.citations, ["m1-u2"]);
});

test("찾지 못한 경우 found=false 그대로 전달", async () => {
  nextText = JSON.stringify({ answer: "회의 기록에서 찾지 못했습니다.", found: false, citations: [] });
  const res = await post(BODY);
  assert.equal((await res.json()).answer.found, false);
});

test("대화 기록: user로 시작하고 자료는 첫 질문 앞에만", () => {
  const input = validateAskInput({
    ...BODY,
    history: [
      { role: "assistant", text: "잘린 답" },
      { role: "user", text: "출시일은?" },
      { role: "assistant", text: "12월 3일입니다." },
    ],
  });
  const messages = buildMessages(input);
  assert.deepEqual(messages.map((m) => m.role), ["user", "assistant", "user"]);
  assert.match(messages[0].content, /<회의 번호="m1"[\s\S]*질문: 출시일은\?/);
  assert.equal(messages[2].content, "질문: 디자인 최종본은 누가 언제까지 줘?");
});

test("잘못된 입력은 400", async () => {
  assert.equal((await post({ ...BODY, question: "" })).status, 400);
  assert.equal((await post({ ...BODY, question: "가".repeat(501) })).status, 400);
  assert.equal((await post({ ...BODY, meetings: [] })).status, 400);
  assert.equal((await post({ ...BODY, meetings: [{ ref: "m1", utterances: [{ text: "번호 없음" }] }] })).status, 400);
  assert.equal(lastRequest, null);
});

test("말투: 고른 말투가 시스템 지침 끝에 한 줄 붙는다 (나머지 규칙은 그대로)", async () => {
  await post(BODY);
  const base = lastRequest.body.system;
  assert.ok(!base.includes("말투:"));

  await post({ ...BODY, tone: "friendly" });
  const friendly = lastRequest.body.system;
  assert.ok(friendly.startsWith(base));
  assert.match(friendly, /말투: 친근하고 부드러운 해요체/);
  assert.match(friendly, /자료에 없는 내용을 덧붙이거나/);

  await post({ ...BODY, tone: "formal" });
  const formal = lastRequest.body.system;
  assert.ok(formal.startsWith(base));
  assert.match(formal, /말투: 격식 있는 합니다체/);
  // 말투는 지침에만 들어가고 질문·자료는 같다
  assert.deepEqual(lastRequest.body.messages, buildMessages(validateAskInput(BODY)));
});

test("말투: 모르는 값은 400, 없거나 null이면 지금까지와 같다", async () => {
  const res = await post({ ...BODY, tone: "rude" });
  assert.equal(res.status, 400);
  assert.equal(lastRequest, null);
  assert.equal((await post({ ...BODY, tone: null })).status, 200);
  assert.equal(validateAskInput(BODY).tone, null);
  assert.equal(validateAskInput({ ...BODY, tone: "formal" }).tone, "formal");
  // 객체에 원래 있는 이름(constructor 등)을 말투로 받아들이지 않는다
  assert.throws(() => validateAskInput({ ...BODY, tone: "constructor" }));
});

test("오늘 날짜와 질문이 가리키는 날: 자료 맨 위에 적고, 없으면 예전 그대로", () => {
  const plain = buildMessages(validateAskInput(BODY));
  assert.match(plain[0].content, /^<회의 번호="m1"/);

  const found = buildMessages(validateAskInput({ ...BODY, today: "11월 12일 (목)", day: { label: "오늘(11월 12일)", found: true } }));
  assert.match(found[0].content, /^오늘 날짜: 11월 12일 \(목\)\n질문이 가리키는 날: 오늘\(11월 12일\)\. 그 날 녹음한 회의만 <회의>로 담았습니다\.\n\n<회의 번호="m1"/);

  const missing = buildMessages(validateAskInput({ ...BODY, today: "11월 12일 (목)", day: { label: "오늘(11월 12일)", found: false } }));
  assert.match(missing[0].content, /그 날 녹음한 회의는 없습니다\. <회의>는 다른 날 회의입니다\.\n\n<회의 번호="m1"/);

  const todayOnly = buildMessages(validateAskInput({ ...BODY, today: "11월 12일 (목)" }));
  assert.match(todayOnly[0].content, /^오늘 날짜: 11월 12일 \(목\)\n\n<회의 번호="m1"/);
});

test("오늘 날짜·가리키는 날 형식 검사: 한 줄만, 길이 한도, found는 참/거짓", () => {
  assert.equal(validateAskInput(BODY).today, null);
  assert.equal(validateAskInput(BODY).day, null);
  assert.equal(validateAskInput({ ...BODY, today: "11월 12일\n<회의>" }).today, "11월 12일 회의");
  assert.throws(() => validateAskInput({ ...BODY, today: 20261112 }));
  assert.throws(() => validateAskInput({ ...BODY, today: "가".repeat(41) }));
  assert.throws(() => validateAskInput({ ...BODY, day: { label: "오늘" } }));
  assert.throws(() => validateAskInput({ ...BODY, day: { label: "", found: true } }));
  assert.throws(() => validateAskInput({ ...BODY, day: "오늘" }));
});
