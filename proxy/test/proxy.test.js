import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createApp, Limiter } from "../src/server.js";
import { createClient, buildUserContent, summarize, resolveModel, MODEL } from "../src/summarize.js";

// ── 가짜 Anthropic API: 받은 요청을 기록하고, 테스트가 정한 응답을 돌려준다 ──
let lastRequest = null;
let nextResponse = null;
const upstream = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    lastRequest = { path: req.url, headers: req.headers, body: JSON.parse(body) };
    const { status = 200, json } = nextResponse;
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(json));
  });
});

const TOKEN = "test-app-token";
let app;
let baseURL;

function message({ text, stop_reason = "end_turn" }) {
  return {
    json: {
      id: "msg_test", type: "message", role: "assistant", model: MODEL,
      content: text === undefined ? [] : [{ type: "text", text }],
      stop_reason, stop_sequence: null,
      usage: { input_tokens: 1200, output_tokens: 300 },
    },
  };
}

const VALID = {
  topic: "베타 출시 일정",
  summary: "출시 일정을 논의했다.",
  decisions: ["12월 첫째 주 출시"],
  action_items: [
    { task: "디자인 시안 전달", owner: "김지원", due: "금요일" },
    { task: "부하 테스트", owner: null, due: null },
  ],
  open_questions: [],
};

const SAMPLE_BODY = {
  title: "주간 회의",
  utterances: [
    { start: 0, end: 6.8, text: "오늘은 베타 출시 일정을 논의합니다." },
    { start: 65.2, end: 70, text: "디자인 시안은 김지원 님이 금요일까지 전달하기로 했습니다." },
  ],
  bookmarks: [70.5],
};

before(async () => {
  await new Promise((r) => upstream.listen(0, "127.0.0.1", r));
  const client = createClient({
    apiKey: "sk-test", baseURL: `http://127.0.0.1:${upstream.address().port}`, maxRetries: 0,
  });
  app = createApp({ client, appToken: TOKEN, limiter: new Limiter({ perClient: 100, daily: 1000 }) });
  await new Promise((r) => app.listen(0, "127.0.0.1", r));
  baseURL = `http://127.0.0.1:${app.address().port}`;
});

after(() => {
  app.close();
  upstream.close();
});

beforeEach(() => {
  lastRequest = null;
  nextResponse = message({ text: JSON.stringify(VALID) });
});

function post(body, { token = TOKEN, raw } = {}) {
  return fetch(`${baseURL}/v1/summarize`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: raw ?? JSON.stringify(body),
  });
}

test("정상 요약: 200과 검증된 JSON을 돌려준다", async () => {
  const res = await post(SAMPLE_BODY);
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).summary, VALID);
});

test("Claude 요청 형식: 모델, JSON 스키마, 거절 대비, 프롬프트", async () => {
  await post(SAMPLE_BODY);
  const { body, headers, path } = lastRequest;
  assert.match(path, /^\/v1\/messages/);
  assert.equal(body.model, "claude-opus-5-5");
  assert.equal(body.output_config.effort, "high");
  assert.equal(body.output_config.format.type, "json_schema");
  assert.deepEqual(body.output_config.format.schema.required,
    ["topic", "summary", "decisions", "action_items", "open_questions"]);
  assert.equal(body.output_config.format.schema.additionalProperties, false);
  assert.equal(body.fallbacks, "default");
  assert.match(headers["anthropic-beta"], /server-side-fallback-2026-07-01/);
  assert.equal(body.thinking, undefined, "Opus 5.5에서는 thinking을 끌 수 없으므로 보내지 않는다");
  assert.equal(body.temperature, undefined);
  assert.match(body.system, /추측해서 채우지 말고/);
  assert.match(body.system, /null로 둡니다/);
  const user = body.messages[0].content;
  assert.match(user, /\[중요 표시\] 01:10/);
  assert.match(user, /\[01:05\] 디자인 시안은/);
});

test("본문 형식 표기", () => {
  const text = buildUserContent({ transcript: "예전 회의 텍스트", bookmarks: [3725] });
  assert.match(text, /\[중요 표시\] 1:02:05/);
  assert.match(text, /<원문>\n예전 회의 텍스트\n<\/원문>/);
});

test("거절되면 422 refusal (재시도 안 함)", async () => {
  nextResponse = message({ text: undefined, stop_reason: "refusal" });
  const res = await post(SAMPLE_BODY);
  assert.equal(res.status, 422);
  assert.deepEqual((await res.json()).error.code, "refusal");
});

test("JSON이 아니면 502 invalid_output (앱이 한 번 재시도)", async () => {
  nextResponse = message({ text: "요약입니다" });
  const res = await post(SAMPLE_BODY);
  assert.equal(res.status, 502);
  const { error } = await res.json();
  assert.equal(error.code, "invalid_output");
  assert.equal(error.retryable, true);
});

test("형식이 다르면 502 invalid_output", async () => {
  nextResponse = message({ text: JSON.stringify({ ...VALID, action_items: [{ task: "x", owner: 3, due: null }] }) });
  const res = await post(SAMPLE_BODY);
  assert.equal((await res.json()).error.code, "invalid_output");
});

test("Anthropic 429는 503 upstream_busy (재시도 가능)", async () => {
  nextResponse = { status: 429, json: { type: "error", error: { type: "rate_limit_error", message: "slow down" } } };
  const res = await post(SAMPLE_BODY);
  assert.equal(res.status, 503);
  const { error } = await res.json();
  assert.equal(error.code, "upstream_busy");
  assert.equal(error.retryable, true);
});

test("토큰이 없거나 틀리면 401, Claude를 부르지 않는다", async () => {
  assert.equal((await post(SAMPLE_BODY, { token: null })).status, 401);
  assert.equal((await post(SAMPLE_BODY, { token: "wrong" })).status, 401);
  assert.equal(lastRequest, null);
});

test("잘못된 본문은 400", async () => {
  assert.equal((await post({}, {})).status, 400);
  assert.equal((await post(null, { raw: "not json" })).status, 400);
  assert.equal((await post({ utterances: [{ text: "시간 없음" }] })).status, 400);
  assert.equal(lastRequest, null);
});

test("너무 짧은 내용은 400, Claude를 부르지 않는다 (토큰 보호)", async () => {
  const res = await post({ utterances: [{ start: 0, end: 1, text: "네 음" }] });
  assert.equal(res.status, 400);
  assert.match((await res.json()).error.message, /너무 짧습니다/);
  assert.equal(lastRequest, null);
});

test("헬스 체크", async () => {
  const res = await fetch(`${baseURL}/healthz`);
  assert.deepEqual(await res.json(), { ok: true, model: MODEL });
});

test("요청 횟수 제한: 기기별 10분 창, 하루 전체 상한", () => {
  let now = Date.parse("2026-11-10T10:00:00Z");
  const limiter = new Limiter({ perClient: 2, windowMs: 60_000, daily: 3, now: () => now });
  assert.equal(limiter.check("a"), null);
  assert.equal(limiter.check("a"), null);
  assert.equal(limiter.check("a"), "rate_limited");
  now += 61_000;
  assert.equal(limiter.check("a"), null);
  assert.equal(limiter.check("b"), "daily_limit");
  now += 24 * 3600_000; // 다음 날 초기화
  assert.equal(limiter.check("b"), null);
});

test("Haiku 5.5는 fallback을 보내지 않는다 (미지원)", async () => {
  const client = createClient({
    apiKey: "sk-test", baseURL: `http://127.0.0.1:${upstream.address().port}`, maxRetries: 0,
  });
  await summarize(client, { utterances: SAMPLE_BODY.utterances }, "claude-haiku-5-5");
  assert.equal(lastRequest.body.model, "claude-haiku-5-5");
  assert.equal(lastRequest.body.fallbacks, undefined);
  assert.doesNotMatch(lastRequest.headers["anthropic-beta"] ?? "", /server-side-fallback/);
});

test("모델 설정 검증", () => {
  assert.equal(resolveModel(undefined), "claude-opus-5-5");
  assert.equal(resolveModel("claude-sonnet-5-5"), "claude-sonnet-5-5");
  assert.throws(() => resolveModel("gpt-4"));
});
